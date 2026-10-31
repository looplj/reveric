// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'ui.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$UiOp {
  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType && other is UiOp);
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() {
    return 'UiOp()';
  }
}

/// @nodoc
class $UiOpCopyWith<$Res> {
  $UiOpCopyWith(UiOp _, $Res Function(UiOp) __);
}

/// Adds pattern-matching-related methods to [UiOp].
extension UiOpPatterns on UiOp {
  /// A variant of `map` that fallback to returning `orElse`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(UiOp_Create value)? create,
    TResult Function(UiOp_Set value)? set_,
    TResult Function(UiOp_Insert value)? insert,
    TResult Function(UiOp_Remove value)? remove,
    TResult Function(UiOp_Listen value)? listen,
    TResult Function(UiOp_Release value)? release,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case UiOp_Create() when create != null:
        return create(_that);
      case UiOp_Set() when set_ != null:
        return set_(_that);
      case UiOp_Insert() when insert != null:
        return insert(_that);
      case UiOp_Remove() when remove != null:
        return remove(_that);
      case UiOp_Listen() when listen != null:
        return listen(_that);
      case UiOp_Release() when release != null:
        return release(_that);
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// Callbacks receives the raw object, upcasted.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case final Subclass2 value:
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(UiOp_Create value) create,
    required TResult Function(UiOp_Set value) set_,
    required TResult Function(UiOp_Insert value) insert,
    required TResult Function(UiOp_Remove value) remove,
    required TResult Function(UiOp_Listen value) listen,
    required TResult Function(UiOp_Release value) release,
  }) {
    final _that = this;
    switch (_that) {
      case UiOp_Create():
        return create(_that);
      case UiOp_Set():
        return set_(_that);
      case UiOp_Insert():
        return insert(_that);
      case UiOp_Remove():
        return remove(_that);
      case UiOp_Listen():
        return listen(_that);
      case UiOp_Release():
        return release(_that);
    }
  }

  /// A variant of `map` that fallback to returning `null`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(UiOp_Create value)? create,
    TResult? Function(UiOp_Set value)? set_,
    TResult? Function(UiOp_Insert value)? insert,
    TResult? Function(UiOp_Remove value)? remove,
    TResult? Function(UiOp_Listen value)? listen,
    TResult? Function(UiOp_Release value)? release,
  }) {
    final _that = this;
    switch (_that) {
      case UiOp_Create() when create != null:
        return create(_that);
      case UiOp_Set() when set_ != null:
        return set_(_that);
      case UiOp_Insert() when insert != null:
        return insert(_that);
      case UiOp_Remove() when remove != null:
        return remove(_that);
      case UiOp_Listen() when listen != null:
        return listen(_that);
      case UiOp_Release() when release != null:
        return release(_that);
      case _:
        return null;
    }
  }

  /// A variant of `when` that fallback to an `orElse` callback.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(BigInt id, String component)? create,
    TResult Function(BigInt id, Map<String, UiValue> props, List<String> unset,
            BigInt? editRevision)?
        set_,
    TResult Function(BigInt parent, BigInt child, String slot, BigInt? before)?
        insert,
    TResult Function(BigInt parent, BigInt child, String slot)? remove,
    TResult Function(BigInt id, String event, BigInt? handler)? listen,
    TResult Function(BigInt id)? release,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case UiOp_Create() when create != null:
        return create(_that.id, _that.component);
      case UiOp_Set() when set_ != null:
        return set_(_that.id, _that.props, _that.unset, _that.editRevision);
      case UiOp_Insert() when insert != null:
        return insert(_that.parent, _that.child, _that.slot, _that.before);
      case UiOp_Remove() when remove != null:
        return remove(_that.parent, _that.child, _that.slot);
      case UiOp_Listen() when listen != null:
        return listen(_that.id, _that.event, _that.handler);
      case UiOp_Release() when release != null:
        return release(_that.id);
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// As opposed to `map`, this offers destructuring.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case Subclass2(:final field2):
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(BigInt id, String component) create,
    required TResult Function(BigInt id, Map<String, UiValue> props,
            List<String> unset, BigInt? editRevision)
        set_,
    required TResult Function(
            BigInt parent, BigInt child, String slot, BigInt? before)
        insert,
    required TResult Function(BigInt parent, BigInt child, String slot) remove,
    required TResult Function(BigInt id, String event, BigInt? handler) listen,
    required TResult Function(BigInt id) release,
  }) {
    final _that = this;
    switch (_that) {
      case UiOp_Create():
        return create(_that.id, _that.component);
      case UiOp_Set():
        return set_(_that.id, _that.props, _that.unset, _that.editRevision);
      case UiOp_Insert():
        return insert(_that.parent, _that.child, _that.slot, _that.before);
      case UiOp_Remove():
        return remove(_that.parent, _that.child, _that.slot);
      case UiOp_Listen():
        return listen(_that.id, _that.event, _that.handler);
      case UiOp_Release():
        return release(_that.id);
    }
  }

  /// A variant of `when` that fallback to returning `null`
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(BigInt id, String component)? create,
    TResult? Function(BigInt id, Map<String, UiValue> props, List<String> unset,
            BigInt? editRevision)?
        set_,
    TResult? Function(BigInt parent, BigInt child, String slot, BigInt? before)?
        insert,
    TResult? Function(BigInt parent, BigInt child, String slot)? remove,
    TResult? Function(BigInt id, String event, BigInt? handler)? listen,
    TResult? Function(BigInt id)? release,
  }) {
    final _that = this;
    switch (_that) {
      case UiOp_Create() when create != null:
        return create(_that.id, _that.component);
      case UiOp_Set() when set_ != null:
        return set_(_that.id, _that.props, _that.unset, _that.editRevision);
      case UiOp_Insert() when insert != null:
        return insert(_that.parent, _that.child, _that.slot, _that.before);
      case UiOp_Remove() when remove != null:
        return remove(_that.parent, _that.child, _that.slot);
      case UiOp_Listen() when listen != null:
        return listen(_that.id, _that.event, _that.handler);
      case UiOp_Release() when release != null:
        return release(_that.id);
      case _:
        return null;
    }
  }
}

/// @nodoc

class UiOp_Create extends UiOp {
  const UiOp_Create({required this.id, required this.component}) : super._();

  final BigInt id;
  final String component;

  /// Create a copy of UiOp
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $UiOp_CreateCopyWith<UiOp_Create> get copyWith =>
      _$UiOp_CreateCopyWithImpl<UiOp_Create>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is UiOp_Create &&
            (identical(other.id, id) || other.id == id) &&
            (identical(other.component, component) ||
                other.component == component));
  }

  @override
  int get hashCode => Object.hash(runtimeType, id, component);

  @override
  String toString() {
    return 'UiOp.create(id: $id, component: $component)';
  }
}

/// @nodoc
abstract mixin class $UiOp_CreateCopyWith<$Res> implements $UiOpCopyWith<$Res> {
  factory $UiOp_CreateCopyWith(
          UiOp_Create value, $Res Function(UiOp_Create) _then) =
      _$UiOp_CreateCopyWithImpl;
  @useResult
  $Res call({BigInt id, String component});
}

/// @nodoc
class _$UiOp_CreateCopyWithImpl<$Res> implements $UiOp_CreateCopyWith<$Res> {
  _$UiOp_CreateCopyWithImpl(this._self, this._then);

  final UiOp_Create _self;
  final $Res Function(UiOp_Create) _then;

  /// Create a copy of UiOp
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? id = null,
    Object? component = null,
  }) {
    return _then(UiOp_Create(
      id: null == id
          ? _self.id
          : id // ignore: cast_nullable_to_non_nullable
              as BigInt,
      component: null == component
          ? _self.component
          : component // ignore: cast_nullable_to_non_nullable
              as String,
    ));
  }
}

/// @nodoc

class UiOp_Set extends UiOp {
  const UiOp_Set(
      {required this.id,
      required final Map<String, UiValue> props,
      required final List<String> unset,
      this.editRevision})
      : _props = props,
        _unset = unset,
        super._();

  final BigInt id;
  final Map<String, UiValue> _props;
  Map<String, UiValue> get props {
    if (_props is EqualUnmodifiableMapView) return _props;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableMapView(_props);
  }

  final List<String> _unset;
  List<String> get unset {
    if (_unset is EqualUnmodifiableListView) return _unset;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_unset);
  }

  final BigInt? editRevision;

  /// Create a copy of UiOp
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $UiOp_SetCopyWith<UiOp_Set> get copyWith =>
      _$UiOp_SetCopyWithImpl<UiOp_Set>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is UiOp_Set &&
            (identical(other.id, id) || other.id == id) &&
            const DeepCollectionEquality().equals(other._props, _props) &&
            const DeepCollectionEquality().equals(other._unset, _unset) &&
            (identical(other.editRevision, editRevision) ||
                other.editRevision == editRevision));
  }

  @override
  int get hashCode => Object.hash(
      runtimeType,
      id,
      const DeepCollectionEquality().hash(_props),
      const DeepCollectionEquality().hash(_unset),
      editRevision);

  @override
  String toString() {
    return 'UiOp.set_(id: $id, props: $props, unset: $unset, editRevision: $editRevision)';
  }
}

/// @nodoc
abstract mixin class $UiOp_SetCopyWith<$Res> implements $UiOpCopyWith<$Res> {
  factory $UiOp_SetCopyWith(UiOp_Set value, $Res Function(UiOp_Set) _then) =
      _$UiOp_SetCopyWithImpl;
  @useResult
  $Res call(
      {BigInt id,
      Map<String, UiValue> props,
      List<String> unset,
      BigInt? editRevision});
}

/// @nodoc
class _$UiOp_SetCopyWithImpl<$Res> implements $UiOp_SetCopyWith<$Res> {
  _$UiOp_SetCopyWithImpl(this._self, this._then);

  final UiOp_Set _self;
  final $Res Function(UiOp_Set) _then;

  /// Create a copy of UiOp
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? id = null,
    Object? props = null,
    Object? unset = null,
    Object? editRevision = freezed,
  }) {
    return _then(UiOp_Set(
      id: null == id
          ? _self.id
          : id // ignore: cast_nullable_to_non_nullable
              as BigInt,
      props: null == props
          ? _self._props
          : props // ignore: cast_nullable_to_non_nullable
              as Map<String, UiValue>,
      unset: null == unset
          ? _self._unset
          : unset // ignore: cast_nullable_to_non_nullable
              as List<String>,
      editRevision: freezed == editRevision
          ? _self.editRevision
          : editRevision // ignore: cast_nullable_to_non_nullable
              as BigInt?,
    ));
  }
}

/// @nodoc

class UiOp_Insert extends UiOp {
  const UiOp_Insert(
      {required this.parent,
      required this.child,
      required this.slot,
      this.before})
      : super._();

  final BigInt parent;
  final BigInt child;
  final String slot;
  final BigInt? before;

  /// Create a copy of UiOp
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $UiOp_InsertCopyWith<UiOp_Insert> get copyWith =>
      _$UiOp_InsertCopyWithImpl<UiOp_Insert>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is UiOp_Insert &&
            (identical(other.parent, parent) || other.parent == parent) &&
            (identical(other.child, child) || other.child == child) &&
            (identical(other.slot, slot) || other.slot == slot) &&
            (identical(other.before, before) || other.before == before));
  }

  @override
  int get hashCode => Object.hash(runtimeType, parent, child, slot, before);

  @override
  String toString() {
    return 'UiOp.insert(parent: $parent, child: $child, slot: $slot, before: $before)';
  }
}

/// @nodoc
abstract mixin class $UiOp_InsertCopyWith<$Res> implements $UiOpCopyWith<$Res> {
  factory $UiOp_InsertCopyWith(
          UiOp_Insert value, $Res Function(UiOp_Insert) _then) =
      _$UiOp_InsertCopyWithImpl;
  @useResult
  $Res call({BigInt parent, BigInt child, String slot, BigInt? before});
}

/// @nodoc
class _$UiOp_InsertCopyWithImpl<$Res> implements $UiOp_InsertCopyWith<$Res> {
  _$UiOp_InsertCopyWithImpl(this._self, this._then);

  final UiOp_Insert _self;
  final $Res Function(UiOp_Insert) _then;

  /// Create a copy of UiOp
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? parent = null,
    Object? child = null,
    Object? slot = null,
    Object? before = freezed,
  }) {
    return _then(UiOp_Insert(
      parent: null == parent
          ? _self.parent
          : parent // ignore: cast_nullable_to_non_nullable
              as BigInt,
      child: null == child
          ? _self.child
          : child // ignore: cast_nullable_to_non_nullable
              as BigInt,
      slot: null == slot
          ? _self.slot
          : slot // ignore: cast_nullable_to_non_nullable
              as String,
      before: freezed == before
          ? _self.before
          : before // ignore: cast_nullable_to_non_nullable
              as BigInt?,
    ));
  }
}

/// @nodoc

class UiOp_Remove extends UiOp {
  const UiOp_Remove(
      {required this.parent, required this.child, required this.slot})
      : super._();

  final BigInt parent;
  final BigInt child;
  final String slot;

  /// Create a copy of UiOp
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $UiOp_RemoveCopyWith<UiOp_Remove> get copyWith =>
      _$UiOp_RemoveCopyWithImpl<UiOp_Remove>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is UiOp_Remove &&
            (identical(other.parent, parent) || other.parent == parent) &&
            (identical(other.child, child) || other.child == child) &&
            (identical(other.slot, slot) || other.slot == slot));
  }

  @override
  int get hashCode => Object.hash(runtimeType, parent, child, slot);

  @override
  String toString() {
    return 'UiOp.remove(parent: $parent, child: $child, slot: $slot)';
  }
}

/// @nodoc
abstract mixin class $UiOp_RemoveCopyWith<$Res> implements $UiOpCopyWith<$Res> {
  factory $UiOp_RemoveCopyWith(
          UiOp_Remove value, $Res Function(UiOp_Remove) _then) =
      _$UiOp_RemoveCopyWithImpl;
  @useResult
  $Res call({BigInt parent, BigInt child, String slot});
}

/// @nodoc
class _$UiOp_RemoveCopyWithImpl<$Res> implements $UiOp_RemoveCopyWith<$Res> {
  _$UiOp_RemoveCopyWithImpl(this._self, this._then);

  final UiOp_Remove _self;
  final $Res Function(UiOp_Remove) _then;

  /// Create a copy of UiOp
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? parent = null,
    Object? child = null,
    Object? slot = null,
  }) {
    return _then(UiOp_Remove(
      parent: null == parent
          ? _self.parent
          : parent // ignore: cast_nullable_to_non_nullable
              as BigInt,
      child: null == child
          ? _self.child
          : child // ignore: cast_nullable_to_non_nullable
              as BigInt,
      slot: null == slot
          ? _self.slot
          : slot // ignore: cast_nullable_to_non_nullable
              as String,
    ));
  }
}

/// @nodoc

class UiOp_Listen extends UiOp {
  const UiOp_Listen({required this.id, required this.event, this.handler})
      : super._();

  final BigInt id;
  final String event;
  final BigInt? handler;

  /// Create a copy of UiOp
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $UiOp_ListenCopyWith<UiOp_Listen> get copyWith =>
      _$UiOp_ListenCopyWithImpl<UiOp_Listen>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is UiOp_Listen &&
            (identical(other.id, id) || other.id == id) &&
            (identical(other.event, event) || other.event == event) &&
            (identical(other.handler, handler) || other.handler == handler));
  }

  @override
  int get hashCode => Object.hash(runtimeType, id, event, handler);

  @override
  String toString() {
    return 'UiOp.listen(id: $id, event: $event, handler: $handler)';
  }
}

/// @nodoc
abstract mixin class $UiOp_ListenCopyWith<$Res> implements $UiOpCopyWith<$Res> {
  factory $UiOp_ListenCopyWith(
          UiOp_Listen value, $Res Function(UiOp_Listen) _then) =
      _$UiOp_ListenCopyWithImpl;
  @useResult
  $Res call({BigInt id, String event, BigInt? handler});
}

/// @nodoc
class _$UiOp_ListenCopyWithImpl<$Res> implements $UiOp_ListenCopyWith<$Res> {
  _$UiOp_ListenCopyWithImpl(this._self, this._then);

  final UiOp_Listen _self;
  final $Res Function(UiOp_Listen) _then;

  /// Create a copy of UiOp
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? id = null,
    Object? event = null,
    Object? handler = freezed,
  }) {
    return _then(UiOp_Listen(
      id: null == id
          ? _self.id
          : id // ignore: cast_nullable_to_non_nullable
              as BigInt,
      event: null == event
          ? _self.event
          : event // ignore: cast_nullable_to_non_nullable
              as String,
      handler: freezed == handler
          ? _self.handler
          : handler // ignore: cast_nullable_to_non_nullable
              as BigInt?,
    ));
  }
}

/// @nodoc

class UiOp_Release extends UiOp {
  const UiOp_Release({required this.id}) : super._();

  final BigInt id;

  /// Create a copy of UiOp
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $UiOp_ReleaseCopyWith<UiOp_Release> get copyWith =>
      _$UiOp_ReleaseCopyWithImpl<UiOp_Release>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is UiOp_Release &&
            (identical(other.id, id) || other.id == id));
  }

  @override
  int get hashCode => Object.hash(runtimeType, id);

  @override
  String toString() {
    return 'UiOp.release(id: $id)';
  }
}

/// @nodoc
abstract mixin class $UiOp_ReleaseCopyWith<$Res>
    implements $UiOpCopyWith<$Res> {
  factory $UiOp_ReleaseCopyWith(
          UiOp_Release value, $Res Function(UiOp_Release) _then) =
      _$UiOp_ReleaseCopyWithImpl;
  @useResult
  $Res call({BigInt id});
}

/// @nodoc
class _$UiOp_ReleaseCopyWithImpl<$Res> implements $UiOp_ReleaseCopyWith<$Res> {
  _$UiOp_ReleaseCopyWithImpl(this._self, this._then);

  final UiOp_Release _self;
  final $Res Function(UiOp_Release) _then;

  /// Create a copy of UiOp
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? id = null,
  }) {
    return _then(UiOp_Release(
      id: null == id
          ? _self.id
          : id // ignore: cast_nullable_to_non_nullable
              as BigInt,
    ));
  }
}

/// @nodoc
mixin _$UiOutput {
  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType && other is UiOutput);
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() {
    return 'UiOutput()';
  }
}

/// @nodoc
class $UiOutputCopyWith<$Res> {
  $UiOutputCopyWith(UiOutput _, $Res Function(UiOutput) __);
}

/// Adds pattern-matching-related methods to [UiOutput].
extension UiOutputPatterns on UiOutput {
  /// A variant of `map` that fallback to returning `orElse`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(UiOutput_Batch value)? batch,
    TResult Function(UiOutput_HostCall value)? hostCall,
    TResult Function(UiOutput_Error value)? error,
    TResult Function(UiOutput_Closed value)? closed,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case UiOutput_Batch() when batch != null:
        return batch(_that);
      case UiOutput_HostCall() when hostCall != null:
        return hostCall(_that);
      case UiOutput_Error() when error != null:
        return error(_that);
      case UiOutput_Closed() when closed != null:
        return closed(_that);
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// Callbacks receives the raw object, upcasted.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case final Subclass2 value:
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(UiOutput_Batch value) batch,
    required TResult Function(UiOutput_HostCall value) hostCall,
    required TResult Function(UiOutput_Error value) error,
    required TResult Function(UiOutput_Closed value) closed,
  }) {
    final _that = this;
    switch (_that) {
      case UiOutput_Batch():
        return batch(_that);
      case UiOutput_HostCall():
        return hostCall(_that);
      case UiOutput_Error():
        return error(_that);
      case UiOutput_Closed():
        return closed(_that);
    }
  }

  /// A variant of `map` that fallback to returning `null`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(UiOutput_Batch value)? batch,
    TResult? Function(UiOutput_HostCall value)? hostCall,
    TResult? Function(UiOutput_Error value)? error,
    TResult? Function(UiOutput_Closed value)? closed,
  }) {
    final _that = this;
    switch (_that) {
      case UiOutput_Batch() when batch != null:
        return batch(_that);
      case UiOutput_HostCall() when hostCall != null:
        return hostCall(_that);
      case UiOutput_Error() when error != null:
        return error(_that);
      case UiOutput_Closed() when closed != null:
        return closed(_that);
      case _:
        return null;
    }
  }

  /// A variant of `when` that fallback to an `orElse` callback.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(UiBatch field0)? batch,
    TResult Function(BigInt callId, String method, UiValue args)? hostCall,
    TResult Function(String code, String message)? error,
    TResult Function()? closed,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case UiOutput_Batch() when batch != null:
        return batch(_that.field0);
      case UiOutput_HostCall() when hostCall != null:
        return hostCall(_that.callId, _that.method, _that.args);
      case UiOutput_Error() when error != null:
        return error(_that.code, _that.message);
      case UiOutput_Closed() when closed != null:
        return closed();
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// As opposed to `map`, this offers destructuring.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case Subclass2(:final field2):
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(UiBatch field0) batch,
    required TResult Function(BigInt callId, String method, UiValue args)
        hostCall,
    required TResult Function(String code, String message) error,
    required TResult Function() closed,
  }) {
    final _that = this;
    switch (_that) {
      case UiOutput_Batch():
        return batch(_that.field0);
      case UiOutput_HostCall():
        return hostCall(_that.callId, _that.method, _that.args);
      case UiOutput_Error():
        return error(_that.code, _that.message);
      case UiOutput_Closed():
        return closed();
    }
  }

  /// A variant of `when` that fallback to returning `null`
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(UiBatch field0)? batch,
    TResult? Function(BigInt callId, String method, UiValue args)? hostCall,
    TResult? Function(String code, String message)? error,
    TResult? Function()? closed,
  }) {
    final _that = this;
    switch (_that) {
      case UiOutput_Batch() when batch != null:
        return batch(_that.field0);
      case UiOutput_HostCall() when hostCall != null:
        return hostCall(_that.callId, _that.method, _that.args);
      case UiOutput_Error() when error != null:
        return error(_that.code, _that.message);
      case UiOutput_Closed() when closed != null:
        return closed();
      case _:
        return null;
    }
  }
}

/// @nodoc

class UiOutput_Batch extends UiOutput {
  const UiOutput_Batch(this.field0) : super._();

  final UiBatch field0;

  /// Create a copy of UiOutput
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $UiOutput_BatchCopyWith<UiOutput_Batch> get copyWith =>
      _$UiOutput_BatchCopyWithImpl<UiOutput_Batch>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is UiOutput_Batch &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode => Object.hash(runtimeType, field0);

  @override
  String toString() {
    return 'UiOutput.batch(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $UiOutput_BatchCopyWith<$Res>
    implements $UiOutputCopyWith<$Res> {
  factory $UiOutput_BatchCopyWith(
          UiOutput_Batch value, $Res Function(UiOutput_Batch) _then) =
      _$UiOutput_BatchCopyWithImpl;
  @useResult
  $Res call({UiBatch field0});
}

/// @nodoc
class _$UiOutput_BatchCopyWithImpl<$Res>
    implements $UiOutput_BatchCopyWith<$Res> {
  _$UiOutput_BatchCopyWithImpl(this._self, this._then);

  final UiOutput_Batch _self;
  final $Res Function(UiOutput_Batch) _then;

  /// Create a copy of UiOutput
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(UiOutput_Batch(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as UiBatch,
    ));
  }
}

/// @nodoc

class UiOutput_HostCall extends UiOutput {
  const UiOutput_HostCall(
      {required this.callId, required this.method, required this.args})
      : super._();

  final BigInt callId;
  final String method;
  final UiValue args;

  /// Create a copy of UiOutput
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $UiOutput_HostCallCopyWith<UiOutput_HostCall> get copyWith =>
      _$UiOutput_HostCallCopyWithImpl<UiOutput_HostCall>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is UiOutput_HostCall &&
            (identical(other.callId, callId) || other.callId == callId) &&
            (identical(other.method, method) || other.method == method) &&
            (identical(other.args, args) || other.args == args));
  }

  @override
  int get hashCode => Object.hash(runtimeType, callId, method, args);

  @override
  String toString() {
    return 'UiOutput.hostCall(callId: $callId, method: $method, args: $args)';
  }
}

/// @nodoc
abstract mixin class $UiOutput_HostCallCopyWith<$Res>
    implements $UiOutputCopyWith<$Res> {
  factory $UiOutput_HostCallCopyWith(
          UiOutput_HostCall value, $Res Function(UiOutput_HostCall) _then) =
      _$UiOutput_HostCallCopyWithImpl;
  @useResult
  $Res call({BigInt callId, String method, UiValue args});

  $UiValueCopyWith<$Res> get args;
}

/// @nodoc
class _$UiOutput_HostCallCopyWithImpl<$Res>
    implements $UiOutput_HostCallCopyWith<$Res> {
  _$UiOutput_HostCallCopyWithImpl(this._self, this._then);

  final UiOutput_HostCall _self;
  final $Res Function(UiOutput_HostCall) _then;

  /// Create a copy of UiOutput
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? callId = null,
    Object? method = null,
    Object? args = null,
  }) {
    return _then(UiOutput_HostCall(
      callId: null == callId
          ? _self.callId
          : callId // ignore: cast_nullable_to_non_nullable
              as BigInt,
      method: null == method
          ? _self.method
          : method // ignore: cast_nullable_to_non_nullable
              as String,
      args: null == args
          ? _self.args
          : args // ignore: cast_nullable_to_non_nullable
              as UiValue,
    ));
  }

  /// Create a copy of UiOutput
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $UiValueCopyWith<$Res> get args {
    return $UiValueCopyWith<$Res>(_self.args, (value) {
      return _then(_self.copyWith(args: value));
    });
  }
}

/// @nodoc

class UiOutput_Error extends UiOutput {
  const UiOutput_Error({required this.code, required this.message}) : super._();

  final String code;
  final String message;

  /// Create a copy of UiOutput
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $UiOutput_ErrorCopyWith<UiOutput_Error> get copyWith =>
      _$UiOutput_ErrorCopyWithImpl<UiOutput_Error>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is UiOutput_Error &&
            (identical(other.code, code) || other.code == code) &&
            (identical(other.message, message) || other.message == message));
  }

  @override
  int get hashCode => Object.hash(runtimeType, code, message);

  @override
  String toString() {
    return 'UiOutput.error(code: $code, message: $message)';
  }
}

/// @nodoc
abstract mixin class $UiOutput_ErrorCopyWith<$Res>
    implements $UiOutputCopyWith<$Res> {
  factory $UiOutput_ErrorCopyWith(
          UiOutput_Error value, $Res Function(UiOutput_Error) _then) =
      _$UiOutput_ErrorCopyWithImpl;
  @useResult
  $Res call({String code, String message});
}

/// @nodoc
class _$UiOutput_ErrorCopyWithImpl<$Res>
    implements $UiOutput_ErrorCopyWith<$Res> {
  _$UiOutput_ErrorCopyWithImpl(this._self, this._then);

  final UiOutput_Error _self;
  final $Res Function(UiOutput_Error) _then;

  /// Create a copy of UiOutput
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? code = null,
    Object? message = null,
  }) {
    return _then(UiOutput_Error(
      code: null == code
          ? _self.code
          : code // ignore: cast_nullable_to_non_nullable
              as String,
      message: null == message
          ? _self.message
          : message // ignore: cast_nullable_to_non_nullable
              as String,
    ));
  }
}

/// @nodoc

class UiOutput_Closed extends UiOutput {
  const UiOutput_Closed() : super._();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType && other is UiOutput_Closed);
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() {
    return 'UiOutput.closed()';
  }
}

/// @nodoc
mixin _$UiValue {
  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType && other is UiValue);
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() {
    return 'UiValue()';
  }
}

/// @nodoc
class $UiValueCopyWith<$Res> {
  $UiValueCopyWith(UiValue _, $Res Function(UiValue) __);
}

/// Adds pattern-matching-related methods to [UiValue].
extension UiValuePatterns on UiValue {
  /// A variant of `map` that fallback to returning `orElse`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(UiValue_Null value)? null_,
    TResult Function(UiValue_Boolean value)? boolean,
    TResult Function(UiValue_Number value)? number,
    TResult Function(UiValue_String value)? string,
    TResult Function(UiValue_Array value)? array,
    TResult Function(UiValue_Object value)? object,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case UiValue_Null() when null_ != null:
        return null_(_that);
      case UiValue_Boolean() when boolean != null:
        return boolean(_that);
      case UiValue_Number() when number != null:
        return number(_that);
      case UiValue_String() when string != null:
        return string(_that);
      case UiValue_Array() when array != null:
        return array(_that);
      case UiValue_Object() when object != null:
        return object(_that);
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// Callbacks receives the raw object, upcasted.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case final Subclass2 value:
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(UiValue_Null value) null_,
    required TResult Function(UiValue_Boolean value) boolean,
    required TResult Function(UiValue_Number value) number,
    required TResult Function(UiValue_String value) string,
    required TResult Function(UiValue_Array value) array,
    required TResult Function(UiValue_Object value) object,
  }) {
    final _that = this;
    switch (_that) {
      case UiValue_Null():
        return null_(_that);
      case UiValue_Boolean():
        return boolean(_that);
      case UiValue_Number():
        return number(_that);
      case UiValue_String():
        return string(_that);
      case UiValue_Array():
        return array(_that);
      case UiValue_Object():
        return object(_that);
    }
  }

  /// A variant of `map` that fallback to returning `null`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(UiValue_Null value)? null_,
    TResult? Function(UiValue_Boolean value)? boolean,
    TResult? Function(UiValue_Number value)? number,
    TResult? Function(UiValue_String value)? string,
    TResult? Function(UiValue_Array value)? array,
    TResult? Function(UiValue_Object value)? object,
  }) {
    final _that = this;
    switch (_that) {
      case UiValue_Null() when null_ != null:
        return null_(_that);
      case UiValue_Boolean() when boolean != null:
        return boolean(_that);
      case UiValue_Number() when number != null:
        return number(_that);
      case UiValue_String() when string != null:
        return string(_that);
      case UiValue_Array() when array != null:
        return array(_that);
      case UiValue_Object() when object != null:
        return object(_that);
      case _:
        return null;
    }
  }

  /// A variant of `when` that fallback to an `orElse` callback.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function()? null_,
    TResult Function(bool field0)? boolean,
    TResult Function(double field0)? number,
    TResult Function(String field0)? string,
    TResult Function(List<UiValue> field0)? array,
    TResult Function(Map<String, UiValue> field0)? object,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case UiValue_Null() when null_ != null:
        return null_();
      case UiValue_Boolean() when boolean != null:
        return boolean(_that.field0);
      case UiValue_Number() when number != null:
        return number(_that.field0);
      case UiValue_String() when string != null:
        return string(_that.field0);
      case UiValue_Array() when array != null:
        return array(_that.field0);
      case UiValue_Object() when object != null:
        return object(_that.field0);
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// As opposed to `map`, this offers destructuring.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case Subclass2(:final field2):
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function() null_,
    required TResult Function(bool field0) boolean,
    required TResult Function(double field0) number,
    required TResult Function(String field0) string,
    required TResult Function(List<UiValue> field0) array,
    required TResult Function(Map<String, UiValue> field0) object,
  }) {
    final _that = this;
    switch (_that) {
      case UiValue_Null():
        return null_();
      case UiValue_Boolean():
        return boolean(_that.field0);
      case UiValue_Number():
        return number(_that.field0);
      case UiValue_String():
        return string(_that.field0);
      case UiValue_Array():
        return array(_that.field0);
      case UiValue_Object():
        return object(_that.field0);
    }
  }

  /// A variant of `when` that fallback to returning `null`
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function()? null_,
    TResult? Function(bool field0)? boolean,
    TResult? Function(double field0)? number,
    TResult? Function(String field0)? string,
    TResult? Function(List<UiValue> field0)? array,
    TResult? Function(Map<String, UiValue> field0)? object,
  }) {
    final _that = this;
    switch (_that) {
      case UiValue_Null() when null_ != null:
        return null_();
      case UiValue_Boolean() when boolean != null:
        return boolean(_that.field0);
      case UiValue_Number() when number != null:
        return number(_that.field0);
      case UiValue_String() when string != null:
        return string(_that.field0);
      case UiValue_Array() when array != null:
        return array(_that.field0);
      case UiValue_Object() when object != null:
        return object(_that.field0);
      case _:
        return null;
    }
  }
}

/// @nodoc

class UiValue_Null extends UiValue {
  const UiValue_Null() : super._();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType && other is UiValue_Null);
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() {
    return 'UiValue.null_()';
  }
}

/// @nodoc

class UiValue_Boolean extends UiValue {
  const UiValue_Boolean(this.field0) : super._();

  final bool field0;

  /// Create a copy of UiValue
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $UiValue_BooleanCopyWith<UiValue_Boolean> get copyWith =>
      _$UiValue_BooleanCopyWithImpl<UiValue_Boolean>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is UiValue_Boolean &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode => Object.hash(runtimeType, field0);

  @override
  String toString() {
    return 'UiValue.boolean(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $UiValue_BooleanCopyWith<$Res>
    implements $UiValueCopyWith<$Res> {
  factory $UiValue_BooleanCopyWith(
          UiValue_Boolean value, $Res Function(UiValue_Boolean) _then) =
      _$UiValue_BooleanCopyWithImpl;
  @useResult
  $Res call({bool field0});
}

/// @nodoc
class _$UiValue_BooleanCopyWithImpl<$Res>
    implements $UiValue_BooleanCopyWith<$Res> {
  _$UiValue_BooleanCopyWithImpl(this._self, this._then);

  final UiValue_Boolean _self;
  final $Res Function(UiValue_Boolean) _then;

  /// Create a copy of UiValue
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(UiValue_Boolean(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as bool,
    ));
  }
}

/// @nodoc

class UiValue_Number extends UiValue {
  const UiValue_Number(this.field0) : super._();

  final double field0;

  /// Create a copy of UiValue
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $UiValue_NumberCopyWith<UiValue_Number> get copyWith =>
      _$UiValue_NumberCopyWithImpl<UiValue_Number>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is UiValue_Number &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode => Object.hash(runtimeType, field0);

  @override
  String toString() {
    return 'UiValue.number(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $UiValue_NumberCopyWith<$Res>
    implements $UiValueCopyWith<$Res> {
  factory $UiValue_NumberCopyWith(
          UiValue_Number value, $Res Function(UiValue_Number) _then) =
      _$UiValue_NumberCopyWithImpl;
  @useResult
  $Res call({double field0});
}

/// @nodoc
class _$UiValue_NumberCopyWithImpl<$Res>
    implements $UiValue_NumberCopyWith<$Res> {
  _$UiValue_NumberCopyWithImpl(this._self, this._then);

  final UiValue_Number _self;
  final $Res Function(UiValue_Number) _then;

  /// Create a copy of UiValue
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(UiValue_Number(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as double,
    ));
  }
}

/// @nodoc

class UiValue_String extends UiValue {
  const UiValue_String(this.field0) : super._();

  final String field0;

  /// Create a copy of UiValue
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $UiValue_StringCopyWith<UiValue_String> get copyWith =>
      _$UiValue_StringCopyWithImpl<UiValue_String>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is UiValue_String &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode => Object.hash(runtimeType, field0);

  @override
  String toString() {
    return 'UiValue.string(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $UiValue_StringCopyWith<$Res>
    implements $UiValueCopyWith<$Res> {
  factory $UiValue_StringCopyWith(
          UiValue_String value, $Res Function(UiValue_String) _then) =
      _$UiValue_StringCopyWithImpl;
  @useResult
  $Res call({String field0});
}

/// @nodoc
class _$UiValue_StringCopyWithImpl<$Res>
    implements $UiValue_StringCopyWith<$Res> {
  _$UiValue_StringCopyWithImpl(this._self, this._then);

  final UiValue_String _self;
  final $Res Function(UiValue_String) _then;

  /// Create a copy of UiValue
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(UiValue_String(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as String,
    ));
  }
}

/// @nodoc

class UiValue_Array extends UiValue {
  const UiValue_Array(final List<UiValue> field0)
      : _field0 = field0,
        super._();

  final List<UiValue> _field0;
  List<UiValue> get field0 {
    if (_field0 is EqualUnmodifiableListView) return _field0;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_field0);
  }

  /// Create a copy of UiValue
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $UiValue_ArrayCopyWith<UiValue_Array> get copyWith =>
      _$UiValue_ArrayCopyWithImpl<UiValue_Array>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is UiValue_Array &&
            const DeepCollectionEquality().equals(other._field0, _field0));
  }

  @override
  int get hashCode =>
      Object.hash(runtimeType, const DeepCollectionEquality().hash(_field0));

  @override
  String toString() {
    return 'UiValue.array(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $UiValue_ArrayCopyWith<$Res>
    implements $UiValueCopyWith<$Res> {
  factory $UiValue_ArrayCopyWith(
          UiValue_Array value, $Res Function(UiValue_Array) _then) =
      _$UiValue_ArrayCopyWithImpl;
  @useResult
  $Res call({List<UiValue> field0});
}

/// @nodoc
class _$UiValue_ArrayCopyWithImpl<$Res>
    implements $UiValue_ArrayCopyWith<$Res> {
  _$UiValue_ArrayCopyWithImpl(this._self, this._then);

  final UiValue_Array _self;
  final $Res Function(UiValue_Array) _then;

  /// Create a copy of UiValue
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(UiValue_Array(
      null == field0
          ? _self._field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as List<UiValue>,
    ));
  }
}

/// @nodoc

class UiValue_Object extends UiValue {
  const UiValue_Object(final Map<String, UiValue> field0)
      : _field0 = field0,
        super._();

  final Map<String, UiValue> _field0;
  Map<String, UiValue> get field0 {
    if (_field0 is EqualUnmodifiableMapView) return _field0;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableMapView(_field0);
  }

  /// Create a copy of UiValue
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $UiValue_ObjectCopyWith<UiValue_Object> get copyWith =>
      _$UiValue_ObjectCopyWithImpl<UiValue_Object>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is UiValue_Object &&
            const DeepCollectionEquality().equals(other._field0, _field0));
  }

  @override
  int get hashCode =>
      Object.hash(runtimeType, const DeepCollectionEquality().hash(_field0));

  @override
  String toString() {
    return 'UiValue.object(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $UiValue_ObjectCopyWith<$Res>
    implements $UiValueCopyWith<$Res> {
  factory $UiValue_ObjectCopyWith(
          UiValue_Object value, $Res Function(UiValue_Object) _then) =
      _$UiValue_ObjectCopyWithImpl;
  @useResult
  $Res call({Map<String, UiValue> field0});
}

/// @nodoc
class _$UiValue_ObjectCopyWithImpl<$Res>
    implements $UiValue_ObjectCopyWith<$Res> {
  _$UiValue_ObjectCopyWithImpl(this._self, this._then);

  final UiValue_Object _self;
  final $Res Function(UiValue_Object) _then;

  /// Create a copy of UiValue
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(UiValue_Object(
      null == field0
          ? _self._field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as Map<String, UiValue>,
    ));
  }
}

// dart format on
