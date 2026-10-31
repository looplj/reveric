//! # Module Tests
//!
//! Tests for the JavaScript module system including dynamic loading,
//! resolution, and module builder functionality.

use crate::api::source::{JsCode, JsModule};

// ============================================================================
// JsCode Tests
// ============================================================================

#[test]
fn test_jscode_code_creation() {
    let code = JsCode::Code("console.log('hello')".to_string());
    assert!(code.is_code());
    assert!(!code.is_path());
    assert!(!code.is_bytes());
}

#[test]
fn test_jscode_path_creation() {
    let code = JsCode::Path("/path/to/script.js".to_string());
    assert!(code.is_path());
    assert!(!code.is_code());
    assert!(!code.is_bytes());
    assert_eq!(code.as_path(), Some("/path/to/script.js"));
}

#[test]
fn test_jscode_bytes_creation() {
    let code = JsCode::Bytes(vec![1, 2, 3]);
    assert!(code.is_bytes());
    assert!(!code.is_code());
    assert!(!code.is_path());
}

#[test]
fn test_jscode_code_helper() {
    let code = JsCode::code("test".to_string());
    assert!(code.is_code());
}

#[test]
fn test_jscode_path_helper() {
    let code = JsCode::path("/test.js".to_string());
    assert!(code.is_path());
}

#[test]
fn test_jscode_bytes_helper() {
    let code = JsCode::bytes(vec![1, 2, 3]);
    assert!(code.is_bytes());
}

#[test]
fn test_jscode_clone() {
    let code = JsCode::Code("test".to_string());
    let cloned = code.clone();
    assert_eq!(code, cloned);
}

#[test]
fn test_jscode_eq() {
    let code1 = JsCode::Code("test".to_string());
    let code2 = JsCode::Code("test".to_string());
    let code3 = JsCode::Code("different".to_string());

    assert_eq!(code1, code2);
    assert_ne!(code1, code3);
}

#[test]
fn test_jscode_hash() {
    use std::collections::HashSet;

    let mut set = HashSet::new();
    set.insert(JsCode::Code("test".to_string()));
    set.insert(JsCode::Code("test".to_string()));

    assert_eq!(set.len(), 1);
}

#[test]
fn test_jscode_ord() {
    let code1 = JsCode::Code("a".to_string());
    let code2 = JsCode::Code("b".to_string());

    assert!(code1 < code2);
}

// ============================================================================
// JsModule Tests
// ============================================================================

#[test]
fn test_jsmodule_new() {
    let module = JsModule::new("test".to_string(), JsCode::Code("code".to_string()));
    assert_eq!(module.name, "test");
}

#[test]
fn test_jsmodule_code() {
    let module = JsModule::code("test".to_string(), "export const x = 1;".to_string());
    assert_eq!(module.name, "test");
    assert!(module.source.is_code());
}

#[test]
fn test_jsmodule_path() {
    let module = JsModule::path("test".to_string(), "/path/to/module.js".to_string());
    assert_eq!(module.name, "test");
    assert!(module.source.is_path());
}

#[test]
fn test_jsmodule_bytes() {
    let module = JsModule::bytes("test".to_string(), vec![1, 2, 3]);
    assert_eq!(module.name, "test");
    assert!(module.source.is_bytes());
}

#[test]
fn test_jsmodule_clone() {
    let module = JsModule::code("test".to_string(), "code".to_string());
    let cloned = module.clone();
    assert_eq!(module.name, cloned.name);
}

#[test]
fn test_jsmodule_eq() {
    let module1 = JsModule::code("test".to_string(), "code".to_string());
    let module2 = JsModule::code("test".to_string(), "code".to_string());
    let module3 = JsModule::code("different".to_string(), "code".to_string());

    assert_eq!(module1, module2);
    assert_ne!(module1, module3);
}

#[test]
fn test_jsmodule_hash() {
    use std::collections::HashSet;

    let mut set = HashSet::new();
    set.insert(JsModule::code("test".to_string(), "code".to_string()));
    set.insert(JsModule::code("test".to_string(), "code".to_string()));

    assert_eq!(set.len(), 1);
}

// ============================================================================
// Source Code Retrieval Tests
// ============================================================================

#[tokio::test]
async fn test_get_raw_source_code_from_code() {
    use crate::api::source::get_raw_source_code;

    let code = JsCode::Code("console.log('test')".to_string());
    let result = get_raw_source_code(code).await;

    assert!(result.is_ok());
    let bytes = result.unwrap();
    assert_eq!(bytes, b"console.log('test')");
}

#[tokio::test]
async fn test_get_raw_source_code_from_bytes() {
    use crate::api::source::get_raw_source_code;

    let data = vec![0xCA, 0xFE, 0xBA, 0xBE];
    let code = JsCode::Bytes(data.clone());
    let result = get_raw_source_code(code).await;

    assert!(result.is_ok());
    assert_eq!(result.unwrap(), data);
}

#[tokio::test]
async fn test_get_raw_source_code_from_nonexistent_path() {
    use crate::api::source::get_raw_source_code;

    let code = JsCode::Path("/nonexistent/path/to/file.js".to_string());
    let result = get_raw_source_code(code).await;

    assert!(result.is_err());
}

#[test]
fn test_get_raw_source_code_sync_from_code() {
    use crate::api::source::get_raw_source_code_sync;

    let code = JsCode::Code("test code".to_string());
    let result = get_raw_source_code_sync(code);

    assert!(result.is_ok());
    assert_eq!(result.unwrap(), b"test code");
}

#[test]
fn test_get_raw_source_code_sync_from_bytes() {
    use crate::api::source::get_raw_source_code_sync;

    let data = vec![1, 2, 3, 4];
    let code = JsCode::Bytes(data.clone());
    let result = get_raw_source_code_sync(code);

    assert!(result.is_ok());
    assert_eq!(result.unwrap(), data);
}

#[test]
fn test_get_raw_source_code_sync_from_nonexistent_path() {
    use crate::api::source::get_raw_source_code_sync;

    let code = JsCode::Path("/nonexistent/file.js".to_string());
    let result = get_raw_source_code_sync(code);

    assert!(result.is_err());
}

// ============================================================================
// Module Builder Tests (through JsBuiltinOptions)
// ============================================================================

#[test]
fn test_builtin_options_to_module_builder() {
    use crate::api::source::JsBuiltinOptions;

    let options = JsBuiltinOptions::essential();
    let _builder = options.to_module_builder();
    // Should not panic
}

#[test]
fn test_builtin_options_all_to_module_builder() {
    use crate::api::source::JsBuiltinOptions;

    let options = JsBuiltinOptions::all();
    let _builder = options.to_module_builder();
    // Should not panic
}

#[test]
fn test_builtin_options_none_to_module_builder() {
    use crate::api::source::JsBuiltinOptions;

    let options = JsBuiltinOptions::none();
    let _builder = options.to_module_builder();
    // Should not panic
}

// ============================================================================
// Dynamic Module Resolver/Loader Tests
// ============================================================================

use super::test_utils::test_with;
use crate::api::module::{
    DynamicModuleEntry, DynamicModuleLoader, DynamicModuleResolver, resolve_relative_specifier,
};
use rquickjs::loader::{Loader, Resolver};
use std::collections::HashMap;
use std::sync::{Arc, RwLock};

#[test]
fn resolve_relative_specifier_preserves_rooted_module_names() {
    for (base, name, expected) in [
        ("pkg/main.js", "./dep.js", "pkg/dep.js"),
        ("/pkg/main.js", "./dep.js", "/pkg/dep.js"),
        ("/pkg/nested/main.js", "../dep.js", "/pkg/dep.js"),
        ("/main.js", "../../dep.js", "/dep.js"),
    ] {
        assert_eq!(resolve_relative_specifier(base, name), expected);
    }
}

#[test]
fn test_dynamic_module_resolver_not_found() {
    test_with(|ctx| {
        let mut resolver = DynamicModuleResolver::default();
        let result = resolver.resolve(&ctx, ".", "nonexistent", None);
        assert!(result.is_err());
    });
}

#[test]
fn test_dynamic_module_resolver_found() {
    test_with(|ctx| {
        // Store module in userdata
        let modules = Arc::new(RwLock::new(HashMap::<String, DynamicModuleEntry>::new()));
        modules.write().unwrap().insert(
            "test-module".to_string(),
            DynamicModuleEntry::Source(b"export const x = 1;".to_vec()),
        );
        let _ = crate::runtime::context_data::store(&ctx, modules);

        let mut resolver = DynamicModuleResolver::default();
        let result = resolver.resolve(&ctx, ".", "test-module", None);
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), "test-module");
    });
}

#[test]
fn test_dynamic_module_loader_not_found() {
    test_with(|ctx| {
        let mut loader = DynamicModuleLoader::default();
        let result = loader.load(&ctx, "nonexistent", None);
        assert!(result.is_err());
    });
}

#[test]
fn test_dynamic_module_loader_found() {
    test_with(|ctx| {
        // Store module in userdata
        let modules = Arc::new(RwLock::new(HashMap::<String, DynamicModuleEntry>::new()));
        modules.write().unwrap().insert(
            "test-module".to_string(),
            DynamicModuleEntry::Source(b"export const x = 1;".to_vec()),
        );
        let _ = crate::runtime::context_data::store(&ctx, modules);

        let mut loader = DynamicModuleLoader::default();
        let result = loader.load(&ctx, "test-module", None);
        assert!(result.is_ok());
    });
}

// ============================================================================
// Module Names Tests
// ============================================================================

use crate::api::module::ModuleNames;
use std::collections::HashSet;

#[test]
fn test_module_names_new() {
    let mut names = HashSet::new();
    names.insert("module1".to_string());
    names.insert("module2".to_string());

    let module_names = ModuleNames::new(names.clone());
    let list = module_names.get_list();

    assert_eq!(list.len(), 2);
    assert!(list.contains("module1"));
    assert!(list.contains("module2"));
}

// ============================================================================
// Global Attachment Tests
// ============================================================================

use crate::api::module::GlobalAttachment;

#[test]
fn test_global_attachment_default() {
    let attachment = GlobalAttachment::default();
    test_with(|ctx| {
        let result = attachment.attach(&ctx);
        assert!(result.is_ok());
    });
}

#[test]
fn test_global_attachment_add_name() {
    let attachment = GlobalAttachment::default().add_name("test-module");
    test_with(|ctx| {
        let result = attachment.attach(&ctx);
        assert!(result.is_ok());
    });
}

#[test]
fn test_global_attachment_add_function() {
    fn init_fn(_ctx: &rquickjs::Ctx<'_>) -> rquickjs::Result<()> {
        Ok(())
    }

    let attachment = GlobalAttachment::default().add_function(init_fn);
    test_with(|ctx| {
        let result = attachment.attach(&ctx);
        assert!(result.is_ok());
    });
}

#[test]
fn test_global_attachment_multiple_attach() {
    let attachment = GlobalAttachment::default();
    test_with(|ctx| {
        // First attach should succeed
        let result1 = attachment.attach(&ctx);
        assert!(result1.is_ok());

        // Second attach should also succeed (idempotent)
        let result2 = attachment.attach(&ctx);
        assert!(result2.is_ok());
    });
}

// ============================================================================
// Module Resolver Tests
// ============================================================================

use crate::api::module::ModuleResolver;

#[test]
fn test_module_resolver_add_name() {
    let resolver = ModuleResolver::default().add_name("test-module");
    test_with(|ctx| {
        let mut resolver = resolver;
        let result = resolver.resolve(&ctx, ".", "test-module", None);
        assert!(result.is_ok());
    });
}

#[test]
fn test_module_resolver_not_found() {
    let resolver = ModuleResolver::default().add_name("existing");
    test_with(|ctx| {
        let mut resolver = resolver;
        let result = resolver.resolve(&ctx, ".", "nonexistent", None);
        assert!(result.is_err());
    });
}

#[test]
fn test_module_resolver_node_prefix() {
    let resolver = ModuleResolver::default().add_name("fs");
    test_with(|ctx| {
        let mut resolver = resolver;
        // Should handle node: prefix
        let result = resolver.resolve(&ctx, ".", "node:fs", None);
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), "fs");
    });
}

// ============================================================================
// Module Builder Tests
// ============================================================================

use crate::api::module::ModuleBuilder;

#[test]
fn test_module_builder_new() {
    let builder = ModuleBuilder::new();
    let (resolver, loader, attachment) = builder.build();
    // Should not panic
    let _ = resolver;
    let _ = loader;
    let _ = attachment;
}

#[test]
fn test_module_builder_with_global() {
    fn init_fn(_ctx: &rquickjs::Ctx<'_>) -> rquickjs::Result<()> {
        Ok(())
    }

    let builder = ModuleBuilder::new().with_global(init_fn);
    let (_resolver, _loader, attachment) = builder.build();

    test_with(|ctx| {
        let result = attachment.attach(&ctx);
        assert!(result.is_ok());
    });
}

/// Real files must not be reachable through any import spelling. A memory
/// module is the positive control: denying every import is not sufficient.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn codemode_external_modules_are_denied() {
    use crate::api::{engine::JsEngine, source::JsBuiltinOptions, value::JsValue};
    let fixture = std::env::current_dir()
        .unwrap()
        .join(format!("codemode-loader-fixture-{}", std::process::id()));
    std::fs::create_dir_all(fixture.join("child")).unwrap();
    std::fs::write(fixture.join("secret.js"), "export const secret = 73;").unwrap();
    let relative = format!(
        "./{}/secret.js",
        fixture.file_name().unwrap().to_str().unwrap()
    );
    let traversal = format!(
        "./{}/child/../secret.js",
        fixture.file_name().unwrap().to_str().unwrap()
    );
    let absolute = fixture.join("secret.js").to_str().unwrap().to_owned();
    let engine = JsEngine::create(
        Some(JsBuiltinOptions::none()),
        Some(vec![JsModule::code(
            "memory-fixture".into(),
            "export const answer = 42;".into(),
        )]),
        None,
    )
    .await
    .unwrap();
    engine.init_without_bridge().await.unwrap();
    for path in [
        relative,
        traversal,
        absolute,
        "/usr/lib/libSystem.B.dylib".into(),
        "libc.so.6".into(),
    ] {
        // Construct the specifier at runtime, without relying on source scanning.
        let code =
            format!("await import({path:?}.split('').join('')).then(() => false, () => true)");
        let result = engine.eval(JsCode::Code(code), None).await.unwrap();
        assert!(
            matches!(result, JsValue::Boolean(true)),
            "external import succeeded: {path}"
        );
    }
    let result = engine
        .eval(
            JsCode::Code("(await import('memory-fixture')).answer".into()),
            None,
        )
        .await
        .unwrap();
    assert!(matches!(result, JsValue::Integer(42)));
    engine.close().await.unwrap();
    std::fs::remove_dir_all(fixture).unwrap();
}
