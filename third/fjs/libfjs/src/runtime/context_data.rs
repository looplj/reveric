//! FJS state keyed by the actual QuickJS context, never by the shared runtime.
//! rquickjs `Ctx::userdata` is runtime-wide; storing a bare value there would
//! let the last-created realm replace every sibling's modules and intrinsics.

use rquickjs::{Ctx, JsLifetime};
use std::any::Any;
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

struct ContextData<T>(RefCell<HashMap<usize, Rc<T>>>);

// SAFETY: T implements JsLifetime; the container neither changes T's layout nor
// exports a JS handle beyond the runtime lock. Every T is rebound uniformly.
unsafe impl<'js, T: JsLifetime<'js>> JsLifetime<'js> for ContextData<T> {
    type Changed<'to> = ContextData<T::Changed<'to>>;
}

pub(crate) fn get<'js, T>(ctx: &Ctx<'js>) -> Option<Rc<T>>
where
    T: JsLifetime<'js>,
    T::Changed<'static>: Any,
{
    let data = ctx.userdata::<ContextData<T>>()?;
    data.0
        .borrow()
        .get(&(ctx.as_raw().as_ptr() as usize))
        .cloned()
}

pub(crate) fn store<'js, T>(ctx: &Ctx<'js>, value: T) -> rquickjs::Result<()>
where
    T: JsLifetime<'js>,
    T::Changed<'static>: Any,
{
    if ctx.userdata::<ContextData<T>>().is_none() {
        ctx.store_userdata(ContextData::<T>(RefCell::new(HashMap::new())))
            .map_err(|error| {
                rquickjs::Error::new_from_js_message("context", "userdata", error.to_string())
            })?;
    }
    let data = ctx
        .userdata::<ContextData<T>>()
        .expect("context data initialized");
    data.0
        .borrow_mut()
        .insert(ctx.as_raw().as_ptr() as usize, Rc::new(value));
    Ok(())
}

fn remove<'js, T>(ctx: &Ctx<'js>)
where
    T: JsLifetime<'js>,
    T::Changed<'static>: Any,
{
    if let Some(data) = ctx.userdata::<ContextData<T>>() {
        data.0
            .borrow_mut()
            .remove(&(ctx.as_raw().as_ptr() as usize));
    }
}

pub(crate) fn clear(ctx: &Ctx<'_>) {
    remove::<crate::api::module::DynamicModuleStorage>(ctx);
    remove::<crate::api::module::LoadedDynamicModules>(ctx);
    remove::<crate::api::module::ModuleNames<'_>>(ctx);
    remove::<crate::api::module::GlobalAttachmentInitialized>(ctx);
    remove::<crate::api::value::ValueIntrinsics<'_>>(ctx);
    remove::<crate::runtime::error_sink::RuntimeErrorSink>(ctx);
}
