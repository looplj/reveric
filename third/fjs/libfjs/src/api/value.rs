//! # JavaScript Value Conversion
//!
//! This module provides type-safe conversion between JavaScript values and Rust types.
//! It supports all primitive JavaScript types as well as complex structures like
//! arrays and objects, enabling seamless data exchange between Dart and JavaScript.
//!
//! ## Features
//!
//! - **Primitive Types**: Numbers, strings, booleans, null/undefined
//! - **Collections**: Arrays and objects with nested support
//! - **BigInt Support**: Safe handling of large integers
//! - **Type Safety**: Compile-time and runtime type checking
//! - **Zero-copy**: Efficient conversion where possible
//! - **ArrayBuffer/TypedArray**: Binary data support

use flutter_rust_bridge::frb;
use rquickjs::function::Constructor;
use rquickjs::object::Property;
use rquickjs::{Ctx, FromAtom, FromJs, IntoJs, JsLifetime, Null, Type};
use std::collections::{HashMap, HashSet};
use std::marker::PhantomData;

const JS_MAX_SAFE_INTEGER: i64 = 9_007_199_254_740_991;
const JS_MIN_SAFE_INTEGER: i64 = -JS_MAX_SAFE_INTEGER;
const MAX_CONVERSION_DEPTH: usize = 128;
const MAX_CONVERSION_NODES: usize = 100_000;

#[frb(ignore)]
pub(crate) struct ValueIntrinsics<'js> {
    date_constructor: rquickjs::Object<'js>,
    date_get_time: rquickjs::Function<'js>,
    array_buffer_constructor: rquickjs::Object<'js>,
    array_buffer_is_view: rquickjs::Function<'js>,
    _marker: PhantomData<&'js ()>,
}

// SAFETY: Every context-bound field (`Object` and `Function`) uses exactly the
// same `'js` lifetime and `Changed` rebinds all of them uniformly to `'to`.
unsafe impl<'js> JsLifetime<'js> for ValueIntrinsics<'js> {
    type Changed<'to> = ValueIntrinsics<'to>;
}

impl<'js> ValueIntrinsics<'js> {
    fn capture(ctx: &Ctx<'js>) -> rquickjs::Result<Self> {
        let global = ctx.globals();
        let date_constructor = global.get::<_, rquickjs::Object>("Date")?;
        let date_prototype = date_constructor.get::<_, rquickjs::Object>("prototype")?;
        let date_get_time = date_prototype.get::<_, rquickjs::Function>("getTime")?;

        let array_buffer: rquickjs::Object = global.get("ArrayBuffer")?;
        let array_buffer_is_view = array_buffer.get::<_, rquickjs::Function>("isView")?;

        Ok(Self {
            date_constructor,
            date_get_time,
            array_buffer_constructor: array_buffer,
            array_buffer_is_view,
            _marker: PhantomData,
        })
    }
}

pub(crate) fn install_value_intrinsics<'js>(
    ctx: &Ctx<'js>,
) -> Result<(), crate::api::error::JsError> {
    if crate::runtime::context_data::get::<ValueIntrinsics<'js>>(&ctx).is_some() {
        return Ok(());
    }

    let intrinsics = ValueIntrinsics::capture(ctx)?;
    crate::runtime::context_data::store(&ctx, intrinsics).map_err(|e| {
        crate::api::error::JsError::context(format!("Failed to store value intrinsics: {e:?}"))
    })?;
    Ok(())
}

fn is_safe_js_integer(value: i64) -> bool {
    (JS_MIN_SAFE_INTEGER..=JS_MAX_SAFE_INTEGER).contains(&value)
}

/// Clears an exception left pending by a probing QuickJS call (for example
/// `JS_GetArrayBuffer` throws a `TypeError` for detached buffers) so it cannot
/// be misattributed to a later, unrelated operation on the context.
fn clear_residual_exception(ctx: &Ctx<'_>) {
    if ctx.has_exception() {
        let _ = ctx.catch();
    }
}

fn detached_buffer_error(from: &'static str) -> rquickjs::Error {
    rquickjs::Error::new_from_js_message(from, "Bytes", "buffer is detached")
}

/// Returns whether `obj` is an `ArrayBuffer` instance, without probing through
/// `JS_GetArrayBuffer` (which throws and leaves a pending exception for every
/// non-ArrayBuffer object).
fn is_array_buffer_instance<'js>(
    ctx: &Ctx<'js>,
    obj: &rquickjs::Object<'js>,
    intrinsics: Option<&ValueIntrinsics<'js>>,
) -> bool {
    let constructor = match intrinsics {
        Some(intrinsics) => intrinsics.array_buffer_constructor.clone(),
        None => match ctx.globals().get::<_, rquickjs::Object>("ArrayBuffer") {
            Ok(constructor) => constructor,
            Err(_) => return false,
        },
    };
    obj.is_instance_of(&constructor)
}

fn dynamic_view_bytes<'js>(
    ctx: &Ctx<'js>,
    obj: &rquickjs::Object<'js>,
    intrinsics: Option<&ValueIntrinsics<'js>>,
) -> rquickjs::Result<Option<Vec<u8>>> {
    macro_rules! try_typed_array_bytes {
        ($($ty:ty),+ $(,)?) => {
            $(
                if let Some(arr) = obj.as_typed_array::<$ty>() {
                    // SAFETY: the slice is copied before any JavaScript can
                    // detach or mutate the backing store.
                    return match unsafe { arr.as_bytes() } {
                        Some(bytes) => Ok(Some(bytes.to_vec())),
                        None => {
                            clear_residual_exception(ctx);
                            Err(detached_buffer_error("TypedArray"))
                        }
                    };
                }
            )+
        };
    }
    try_typed_array_bytes!(i8, u8, i16, u16, i32, u32, f32, f64, i64, u64);

    let is_view = if let Some(intrinsics) = intrinsics {
        intrinsics
            .array_buffer_is_view
            .call::<_, bool>((obj.clone(),))
            .unwrap_or(false)
    } else {
        let global = ctx.globals();
        match global
            .get::<_, rquickjs::Object>("ArrayBuffer")
            .and_then(|array_buffer| array_buffer.get::<_, rquickjs::Function>("isView"))
        {
            Ok(is_view) => is_view.call::<_, bool>((obj.clone(),)).unwrap_or(false),
            Err(_) => false,
        }
    };

    if !is_view {
        return Ok(None);
    }

    let buffer = obj.get::<_, rquickjs::Object>("buffer")?;
    let byte_offset = obj.get::<_, usize>("byteOffset")?;
    let byte_length = obj.get::<_, usize>("byteLength")?;
    let Some(array_buffer) = rquickjs::ArrayBuffer::from_object(buffer) else {
        clear_residual_exception(ctx);
        return Err(detached_buffer_error("DataView"));
    };
    // SAFETY: the slice is copied before any JavaScript can detach or mutate
    // the backing store.
    let bytes = unsafe { array_buffer.as_bytes() };
    let Some(bytes) = bytes else {
        clear_residual_exception(ctx);
        return Err(detached_buffer_error("DataView"));
    };
    let end = byte_offset.checked_add(byte_length).ok_or_else(|| {
        rquickjs::Error::new_from_js_message("value", "Bytes", "Binary view overflow")
    })?;
    let slice = bytes.get(byte_offset..end).ok_or_else(|| {
        rquickjs::Error::new_from_js_message("value", "Bytes", "Binary view is out of bounds")
    })?;
    Ok(Some(slice.to_vec()))
}

fn date_millis<'js>(
    ctx: &Ctx<'js>,
    obj: &rquickjs::Object<'js>,
    intrinsics: Option<&ValueIntrinsics<'js>>,
) -> rquickjs::Result<Option<i64>> {
    let (date_constructor, date_get_time) = if let Some(intrinsics) = intrinsics {
        (
            intrinsics.date_constructor.clone(),
            intrinsics.date_get_time.clone(),
        )
    } else {
        let global = ctx.globals();
        let date_constructor = match global.get::<_, rquickjs::Object>("Date") {
            Ok(value) => value,
            Err(_) => return Ok(None),
        };
        let date_prototype = match date_constructor.get::<_, rquickjs::Object>("prototype") {
            Ok(value) => value,
            Err(_) => return Ok(None),
        };
        let date_get_time = match date_prototype.get::<_, rquickjs::Function>("getTime") {
            Ok(value) => value,
            Err(_) => return Ok(None),
        };
        (date_constructor, date_get_time)
    };

    if !obj.is_instance_of(&date_constructor) {
        return Ok(None);
    }

    let ms = date_get_time
        .call::<_, f64>((rquickjs::function::This(obj.clone()),))
        .map_err(|e| rquickjs::Error::new_from_js_message("Date", "number", e.to_string()))?;

    if !ms.is_finite() {
        return Err(rquickjs::Error::new_from_js_message(
            "Date",
            "JsValue::Date",
            "Invalid Date cannot be converted to JsValue::Date",
        ));
    }

    Ok(Some(ms as i64))
}

/// Represents a JavaScript value with type-safe conversion.
///
/// This enum provides a comprehensive representation of all JavaScript value types,
/// enabling safe and efficient conversion between JavaScript and Rust/Dart values.
/// Each variant corresponds to a specific JavaScript type.
#[derive(Debug, Clone, Default, PartialEq)]
#[frb(dart_metadata = ("freezed"), dart_code = r#"

  /// Creates a JsValue from any Dart object.
  static JsValue from(Object? any) {
    if (any == null) {
      return const JsValue.none();
    } else if (any is bool) {
      return JsValue.boolean(any);
    } else if (any is int) {
      const maxSafeInteger = 9007199254740991;
      if (any > maxSafeInteger || any < -maxSafeInteger) {
        return JsValue.bigint(any.toString());
      }
      return JsValue.integer(any);
    } else if (any is double) {
      return JsValue.float(any);
    } else if (any is BigInt) {
      return JsValue.bigint(any.toString());
    } else if (any is String) {
      return JsValue.string(any);
    } else if (any is Uint8List) {
      return JsValue.bytes(any);
    } else if (any is List) {
      return JsValue.array(any.map((e) => from(e)).toList());
    } else if (any is Map) {
      return JsValue.object(
        any.map((key, value) => MapEntry(key.toString(), from(value))),
      );
    } else {
      throw Exception("Unsupported type: ${any.runtimeType}");
    }
  }

  /// Gets the underlying Dart value.
  dynamic get value => when(
        none: () => null,
        boolean: (v) => v,
        integer: (v) => v,
        float: (v) => v,
        bigint: (v) => BigInt.parse(v),
        string: (v) => v,
        bytes: (v) => v,
        array: (v) => v.map((e) => e.value).toList(),
        object: (v) => v.map((key, value) => MapEntry(key, value.value)),
        date: (ms) => DateTime.fromMillisecondsSinceEpoch(ms.toInt()),
        symbol: (v) => v,
        function: (v) => v,
      );

  /// Safe casting methods
  bool? get asBoolean => this is JsValue_Boolean ? (this as JsValue_Boolean).field0 : null;
  int? get asInteger => this is JsValue_Integer ? (this as JsValue_Integer).field0 : null;
  double? get asFloat => this is JsValue_Float ? (this as JsValue_Float).field0 : null;
  String? get asBigint => this is JsValue_Bigint ? (this as JsValue_Bigint).field0 : null;
  String? get asString => this is JsValue_String ? (this as JsValue_String).field0 : null;
  Uint8List? get asBytes => this is JsValue_Bytes ? (this as JsValue_Bytes).field0 : null;
  List<JsValue>? get asArray => this is JsValue_Array ? (this as JsValue_Array).field0 : null;
  Map<String, JsValue>? get asObject => this is JsValue_Object ? (this as JsValue_Object).field0 : null;

  /// Converts to num if possible.
  num? get asNum {
    if (this is JsValue_Integer) return (this as JsValue_Integer).field0;
    if (this is JsValue_Float) return (this as JsValue_Float).field0;
    if (this is JsValue_Bigint) {
      final bigint = BigInt.parse((this as JsValue_Bigint).field0);
      if (bigint >= BigInt.from(-9007199254740991) && bigint <= BigInt.from(9007199254740991)) {
        return bigint.toInt();
      }
    }
    return null;
  }
"#)]
pub enum JsValue {
    /// Represents null or undefined values in JavaScript
    #[default]
    None,
    /// Represents boolean values (true/false)
    Boolean(bool),
    /// Represents JavaScript safe integers (`Number` within +/- 2^53 - 1)
    Integer(i64),
    /// Represents floating-point number values
    Float(f64),
    /// Represents BigInt values stored as strings for precision
    Bigint(String),
    /// Represents string values
    String(String),
    /// Represents binary data (ArrayBuffer or typed array bytes)
    Bytes(Vec<u8>),
    /// Represents arrays with nested value support
    Array(Vec<JsValue>),
    /// Represents objects with string keys and arbitrary values
    Object(HashMap<String, JsValue>),
    /// Represents Date objects (milliseconds since epoch)
    Date(i64),
    /// Represents Symbol values (description)
    Symbol(String),
    /// Represents function references (serialized name/id)
    Function(String),
}

impl JsValue {
    /// Creates a None value.
    ///
    /// Represents null or undefined in JavaScript.
    ///
    /// ## Returns
    ///
    /// A `JsValue::None` instance
    #[frb(ignore)]
    pub fn none() -> Self {
        JsValue::None
    }

    /// Creates a boolean value.
    ///
    /// ## Parameters
    ///
    /// - `v`: The boolean value
    ///
    /// ## Returns
    ///
    /// A `JsValue::Boolean` instance
    #[frb(ignore)]
    pub fn boolean(v: bool) -> Self {
        JsValue::Boolean(v)
    }

    /// Creates an integer value.
    ///
    /// ## Parameters
    ///
    /// - `v`: The integer value
    ///
    /// ## Returns
    ///
    /// A `JsValue::Integer` instance
    #[frb(ignore)]
    pub fn integer(v: i64) -> Self {
        JsValue::Integer(v)
    }

    /// Creates a float value.
    ///
    /// ## Parameters
    ///
    /// - `v`: The floating-point value
    ///
    /// ## Returns
    ///
    /// A `JsValue::Float` instance
    #[frb(ignore)]
    pub fn float(v: f64) -> Self {
        JsValue::Float(v)
    }

    /// Creates a bigint value from a string.
    ///
    /// BigInt values are stored as strings to preserve precision
    /// for arbitrarily large integers.
    ///
    /// ## Parameters
    ///
    /// - `v`: The bigint value as a string
    ///
    /// ## Returns
    ///
    /// A `JsValue::Bigint` instance
    #[frb(ignore)]
    pub fn bigint<S: Into<String>>(v: S) -> Self {
        JsValue::Bigint(v.into())
    }

    /// Creates a string value.
    ///
    /// ## Parameters
    ///
    /// - `v`: The string value
    ///
    /// ## Returns
    ///
    /// A `JsValue::String` instance
    #[frb(ignore)]
    pub fn string<S: Into<String>>(v: S) -> Self {
        JsValue::String(v.into())
    }

    /// Creates a bytes value.
    ///
    /// Represents binary data (ArrayBuffer/TypedArray in JavaScript).
    ///
    /// ## Parameters
    ///
    /// - `v`: The byte array
    ///
    /// ## Returns
    ///
    /// A `JsValue::Bytes` instance
    #[frb(ignore)]
    pub fn bytes(v: Vec<u8>) -> Self {
        JsValue::Bytes(v)
    }

    /// Creates an array value.
    ///
    /// ## Parameters
    ///
    /// - `v`: The array of `JsValue` elements
    ///
    /// ## Returns
    ///
    /// A `JsValue::Array` instance
    #[frb(ignore)]
    pub fn array(v: Vec<JsValue>) -> Self {
        JsValue::Array(v)
    }

    /// Creates an object value.
    ///
    /// ## Parameters
    ///
    /// - `v`: The object as a HashMap with string keys
    ///
    /// ## Returns
    ///
    /// A `JsValue::Object` instance
    #[frb(ignore)]
    pub fn object(v: HashMap<String, JsValue>) -> Self {
        JsValue::Object(v)
    }

    /// Creates a date value from milliseconds since epoch.
    ///
    /// ## Parameters
    ///
    /// - `ms`: Milliseconds since January 1, 1970, 00:00:00 UTC
    ///
    /// ## Returns
    ///
    /// A `JsValue::Date` instance
    #[frb(ignore)]
    pub fn date(ms: i64) -> Self {
        JsValue::Date(ms)
    }

    /// Returns true if the value is None.
    ///
    /// ## Returns
    ///
    /// `true` if the value is `JsValue::None`, `false` otherwise
    #[frb(sync)]
    pub fn is_none(&self) -> bool {
        matches!(self, JsValue::None)
    }

    /// Returns true if the value is a boolean.
    ///
    /// ## Returns
    ///
    /// `true` if the value is `JsValue::Boolean`, `false` otherwise
    #[frb(sync)]
    pub fn is_boolean(&self) -> bool {
        matches!(self, JsValue::Boolean(_))
    }

    /// Returns true if the value is a number (integer, float, or bigint).
    ///
    /// ## Returns
    ///
    /// `true` if the value is any numeric type, `false` otherwise
    #[frb(sync)]
    pub fn is_number(&self) -> bool {
        matches!(
            self,
            JsValue::Integer(_) | JsValue::Float(_) | JsValue::Bigint(_)
        )
    }

    /// Returns true if the value is a string.
    ///
    /// ## Returns
    ///
    /// `true` if the value is `JsValue::String`, `false` otherwise
    #[frb(sync)]
    pub fn is_string(&self) -> bool {
        matches!(self, JsValue::String(_))
    }

    /// Returns true if the value is an array.
    ///
    /// ## Returns
    ///
    /// `true` if the value is `JsValue::Array`, `false` otherwise
    #[frb(sync)]
    pub fn is_array(&self) -> bool {
        matches!(self, JsValue::Array(_))
    }

    /// Returns true if the value is an object.
    ///
    /// ## Returns
    ///
    /// `true` if the value is `JsValue::Object`, `false` otherwise
    #[frb(sync)]
    pub fn is_object(&self) -> bool {
        matches!(self, JsValue::Object(_))
    }

    /// Returns true if the value is a Date.
    ///
    /// ## Returns
    ///
    /// `true` if the value is `JsValue::Date`, `false` otherwise
    #[frb(sync)]
    pub fn is_date(&self) -> bool {
        matches!(self, JsValue::Date(_))
    }

    /// Returns true if the value is bytes (binary data).
    ///
    /// ## Returns
    ///
    /// `true` if the value is `JsValue::Bytes`, `false` otherwise
    #[frb(sync)]
    pub fn is_bytes(&self) -> bool {
        matches!(self, JsValue::Bytes(_))
    }

    /// Returns true if the value is a primitive type.
    ///
    /// Primitive types include: None, Boolean, Integer, Float, Bigint, and String.
    ///
    /// ## Returns
    ///
    /// `true` if the value is a primitive type, `false` otherwise
    #[frb(sync)]
    pub fn is_primitive(&self) -> bool {
        matches!(
            self,
            JsValue::None
                | JsValue::Boolean(_)
                | JsValue::Integer(_)
                | JsValue::Float(_)
                | JsValue::Bigint(_)
                | JsValue::String(_)
        )
    }

    /// Returns the type name of this value.
    ///
    /// Returns a string representation of the JavaScript type name.
    ///
    /// ## Returns
    ///
    /// The type name as a string (e.g., "null", "boolean", "number", "string", "Array", "Object", etc.)
    ///
    /// ## Example
    ///
    /// ```dart
    /// final value = JsValue.string("hello");
    /// print(value.typeName()); // "string"
    /// ```
    #[frb(sync)]
    pub fn type_name(&self) -> String {
        match self {
            JsValue::None => "null".to_string(),
            JsValue::Boolean(_) => "boolean".to_string(),
            JsValue::Integer(_) => "number".to_string(),
            JsValue::Float(_) => "number".to_string(),
            JsValue::Bigint(_) => "bigint".to_string(),
            JsValue::String(_) => "string".to_string(),
            JsValue::Bytes(_) => "ArrayBuffer".to_string(),
            JsValue::Array(_) => "Array".to_string(),
            JsValue::Object(_) => "Object".to_string(),
            JsValue::Date(_) => "Date".to_string(),
            JsValue::Symbol(_) => "symbol".to_string(),
            JsValue::Function(_) => "function".to_string(),
        }
    }
}

#[frb(ignore)]
#[derive(Default)]
struct ConversionState<'js> {
    active_objects: HashSet<rquickjs::Object<'js>>,
    depth: usize,
    nodes: usize,
}

impl<'js> ConversionState<'js> {
    fn node_limit_error() -> rquickjs::Error {
        rquickjs::Error::new_from_js_message(
            "JavaScript value",
            "JsValue",
            format!("maximum conversion node count of {MAX_CONVERSION_NODES} exceeded"),
        )
    }

    fn depth_limit_error() -> rquickjs::Error {
        rquickjs::Error::new_from_js_message(
            "JavaScript value",
            "JsValue",
            format!("maximum conversion depth of {MAX_CONVERSION_DEPTH} exceeded"),
        )
    }

    fn count_node(&mut self) -> rquickjs::Result<()> {
        let next = self.nodes.checked_add(1).ok_or_else(|| {
            rquickjs::Error::new_from_js_message(
                "JavaScript value",
                "JsValue",
                "conversion node count overflowed",
            )
        })?;
        if next > MAX_CONVERSION_NODES {
            return Err(Self::node_limit_error());
        }
        self.nodes = next;
        Ok(())
    }

    fn ensure_nodes_available(&self, additional: usize) -> rquickjs::Result<()> {
        let remaining = MAX_CONVERSION_NODES.saturating_sub(self.nodes);
        if additional > remaining {
            return Err(Self::node_limit_error());
        }
        Ok(())
    }

    fn with_object<T>(
        &mut self,
        object: &rquickjs::Object<'js>,
        convert: impl FnOnce(&mut Self) -> rquickjs::Result<T>,
    ) -> rquickjs::Result<T> {
        if self.depth >= MAX_CONVERSION_DEPTH {
            return Err(Self::depth_limit_error());
        }
        if !self.active_objects.insert(object.clone()) {
            return Err(rquickjs::Error::new_from_js_message(
                "JavaScript value",
                "JsValue",
                "cyclic JavaScript value",
            ));
        }

        self.depth += 1;
        let result = convert(self);
        self.depth -= 1;
        self.active_objects.remove(object);
        result
    }
}

impl JsValue {
    fn from_js_with_state<'js>(
        ctx: &Ctx<'js>,
        value: rquickjs::Value<'js>,
        state: &mut ConversionState<'js>,
    ) -> rquickjs::Result<Self> {
        state.count_node()?;
        let v = match value.type_of() {
            Type::String => {
                let s = value
                    .as_string()
                    .ok_or_else(|| rquickjs::Error::new_from_js("value", "String"))?;
                JsValue::String(s.to_string()?)
            }
            Type::Array => {
                let arr = value
                    .as_array()
                    .ok_or_else(|| rquickjs::Error::new_from_js("value", "Array"))?;
                state.ensure_nodes_available(arr.len())?;
                let object = arr.as_object().clone();
                let vec = state.with_object(&object, |state| {
                    let mut vec = Vec::with_capacity(arr.len());
                    for item in arr.iter() {
                        let item = item?;
                        let value = JsValue::from_js_with_state(ctx, item, state)?;
                        vec.push(value);
                    }
                    Ok(vec)
                })?;
                JsValue::Array(vec)
            }
            Type::Object => {
                let obj = value
                    .as_object()
                    .ok_or_else(|| rquickjs::Error::new_from_js("value", "Object"))?;
                let intrinsics = crate::runtime::context_data::get::<ValueIntrinsics<'js>>(&ctx);

                // Check for ArrayBuffer. The instanceof gate matters:
                // `ArrayBuffer::from_object` probes via `JS_GetArrayBuffer`,
                // which throws a TypeError for every non-ArrayBuffer object
                // and would leave that exception pending on the context.
                if is_array_buffer_instance(ctx, obj, intrinsics.as_deref()) {
                    // SAFETY: the slice is copied before any JavaScript can
                    // detach or mutate the backing store.
                    let bytes = rquickjs::ArrayBuffer::from_object(obj.clone())
                        .and_then(|ab| unsafe { ab.as_bytes() }.map(|bytes| bytes.to_vec()));
                    return match bytes {
                        Some(bytes) => Ok(JsValue::Bytes(bytes)),
                        None => {
                            clear_residual_exception(ctx);
                            Err(detached_buffer_error("ArrayBuffer"))
                        }
                    };
                }

                if let Some(bytes) = dynamic_view_bytes(ctx, obj, intrinsics.as_deref())? {
                    return Ok(JsValue::Bytes(bytes));
                }

                if let Some(ms) = date_millis(ctx, obj, intrinsics.as_deref())? {
                    return Ok(JsValue::Date(ms));
                }

                // Regular object
                let object = obj.clone();
                let map = state.with_object(&object, |state| {
                    let mut map = HashMap::new();
                    for prop in obj.props() {
                        let (k, v) = prop?;
                        let value = JsValue::from_js_with_state(ctx, v, state)?;
                        map.insert(String::from_atom(k)?, value);
                    }
                    Ok(map)
                })?;
                JsValue::Object(map)
            }
            Type::Int => {
                let i = value
                    .as_int()
                    .ok_or_else(|| rquickjs::Error::new_from_js("value", "Int"))?;
                JsValue::Integer(i as i64)
            }
            Type::Bool => {
                let b = value
                    .as_bool()
                    .ok_or_else(|| rquickjs::Error::new_from_js("value", "Bool"))?;
                JsValue::Boolean(b)
            }
            Type::Float => {
                let f = value
                    .as_float()
                    .ok_or_else(|| rquickjs::Error::new_from_js("value", "Float"))?;
                JsValue::Float(f)
            }
            Type::BigInt => {
                let global = ctx.globals();
                let to_string = global
                    .get::<_, rquickjs::Function>("String")
                    .map_err(|_| rquickjs::Error::new_from_js("value", "BigInt"))?;
                let s = to_string
                    .call::<_, rquickjs::String>((value.clone(),))
                    .map_err(|_| rquickjs::Error::new_from_js("value", "BigInt"))?;
                JsValue::Bigint(s.to_string()?)
            }
            Type::Symbol => {
                // Get symbol description using native rquickjs Symbol API
                if let Some(symbol) = value.as_symbol() {
                    match symbol.description() {
                        Ok(desc) => {
                            if desc.is_undefined() {
                                JsValue::Symbol(String::new())
                            } else if let Some(s) = desc.as_string() {
                                JsValue::Symbol(s.to_string().unwrap_or_default())
                            } else {
                                JsValue::Symbol(String::new())
                            }
                        }
                        Err(_) => JsValue::Symbol(String::new()),
                    }
                } else {
                    JsValue::Symbol(String::new())
                }
            }
            Type::Function | Type::Constructor => {
                // Serialize function name if available
                if let Some(func) = value.as_function() {
                    if let Ok(name) = func.get::<_, String>("name") {
                        JsValue::Function(name)
                    } else {
                        JsValue::Function("<anonymous>".to_string())
                    }
                } else {
                    JsValue::None
                }
            }
            Type::Uninitialized
            | Type::Undefined
            | Type::Null
            | Type::Promise
            | Type::Exception
            | Type::Module
            | Type::Proxy
            | Type::Unknown => JsValue::None,
        };
        Ok(v)
    }
}

impl<'js> FromJs<'js> for JsValue {
    /// Converts a JavaScript value to a JsValue enum.
    fn from_js(ctx: &Ctx<'js>, value: rquickjs::Value<'js>) -> rquickjs::Result<Self> {
        JsValue::from_js_with_state(ctx, value, &mut ConversionState::default())
    }
}

impl<'js> IntoJs<'js> for JsValue {
    /// Converts a JsValue to a JavaScript value.
    fn into_js(self, ctx: &Ctx<'js>) -> rquickjs::Result<rquickjs::Value<'js>> {
        match self {
            JsValue::None => Null.into_js(ctx),
            JsValue::Boolean(v) => Ok(rquickjs::Value::new_bool(ctx.clone(), v)),
            JsValue::Integer(v) => {
                if !is_safe_js_integer(v) {
                    return Err(rquickjs::Error::new_from_js_message(
                        "i64",
                        "number",
                        "Integer exceeds JavaScript's safe integer range; use JsValue::Bigint instead",
                    ));
                }
                Ok(rquickjs::Value::new_number(ctx.clone(), v as _))
            }
            JsValue::Float(v) => Ok(rquickjs::Value::new_float(ctx.clone(), v)),
            JsValue::Bigint(v) => {
                let global = ctx.globals();
                let bigint_constructor: rquickjs::Function = global.get("BigInt")?;
                bigint_constructor.call::<_, rquickjs::Value>((v,))
            }
            JsValue::String(v) => rquickjs::String::from_str(ctx.clone(), &v)?.into_js(ctx),
            JsValue::Bytes(v) => {
                let ab = rquickjs::ArrayBuffer::new(ctx.clone(), v)?;
                ab.into_js(ctx)
            }
            JsValue::Array(v) => {
                let arr = rquickjs::Array::new(ctx.clone())?;
                for (i, item) in v.into_iter().enumerate() {
                    arr.set(i, item.into_js(ctx)?)?;
                }
                arr.into_js(ctx)
            }
            JsValue::Object(v) => {
                let obj = rquickjs::Object::new(ctx.clone())?;
                for (k, val) in v.into_iter() {
                    obj.prop(
                        k,
                        Property::from(val).writable().enumerable().configurable(),
                    )?;
                }
                obj.into_js(ctx)
            }
            JsValue::Date(ms) => {
                // Create a Date object using the constructor
                let global = ctx.globals();
                let date_constructor: Constructor = global.get("Date")?;
                let date = date_constructor.construct::<_, rquickjs::Value>((ms as f64,))?;
                Ok(date)
            }
            JsValue::Symbol(desc) => {
                let global = ctx.globals();
                let symbol_constructor: rquickjs::Function = global.get("Symbol")?;
                let symbol = symbol_constructor.call::<_, rquickjs::Value>((desc,))?;
                Ok(symbol)
            }
            JsValue::Function(_) => {
                // Cannot recreate functions, return undefined
                Ok(rquickjs::Value::new_undefined(ctx.clone()))
            }
        }
    }
}

// Implement From traits for common types
impl From<bool> for JsValue {
    fn from(v: bool) -> Self {
        JsValue::Boolean(v)
    }
}

impl From<i32> for JsValue {
    fn from(v: i32) -> Self {
        JsValue::Integer(v as i64)
    }
}

impl From<i64> for JsValue {
    fn from(v: i64) -> Self {
        JsValue::Integer(v)
    }
}

impl From<f64> for JsValue {
    fn from(v: f64) -> Self {
        JsValue::Float(v)
    }
}

impl From<String> for JsValue {
    fn from(v: String) -> Self {
        JsValue::String(v)
    }
}

impl From<&str> for JsValue {
    fn from(v: &str) -> Self {
        JsValue::String(v.to_string())
    }
}

impl From<Vec<u8>> for JsValue {
    fn from(v: Vec<u8>) -> Self {
        JsValue::Bytes(v)
    }
}

impl<T: Into<JsValue>> From<Vec<T>> for JsValue {
    fn from(v: Vec<T>) -> Self {
        JsValue::Array(v.into_iter().map(|x| x.into()).collect())
    }
}

impl<T: Into<JsValue>> From<Option<T>> for JsValue {
    fn from(v: Option<T>) -> Self {
        match v {
            Some(v) => v.into(),
            None => JsValue::None,
        }
    }
}

impl From<()> for JsValue {
    fn from(_: ()) -> Self {
        JsValue::None
    }
}
