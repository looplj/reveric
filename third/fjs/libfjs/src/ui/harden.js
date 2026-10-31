// Source: nsh d5225a854084ed5e1a3b66c47aa30388b975f4e9 crates/nsh-js/src/sandbox.rs HARDEN (Apache-2.0).
// Runs after the host scripts and before the plugin view: removes every way
// from a string to code and freezes the shared prototypes.
(() => {
  const deny = (label) => function () {
    throw new TypeError(label + " is disabled: plugin views cannot run code from strings");
  };
  const replace = (fn, value) => {
    Object.defineProperty(Object.getPrototypeOf(fn), "constructor", {
      value, writable: false, enumerable: false, configurable: false,
    });
  };
  const blocked = deny("the Function constructor");
  blocked.prototype = Function.prototype;
  replace(function () {}, blocked);
  replace(async function () {}, deny("the AsyncFunction constructor"));
  replace(function* () {}, deny("the GeneratorFunction constructor"));
  replace(async function* () {}, deny("the AsyncGeneratorFunction constructor"));
  Object.defineProperty(globalThis, "Function", { value: blocked, writable: false, configurable: false });
  delete globalThis.eval;
  // Assigning a property an object inherits read-only fails (the "override
  // mistake"), so `Sub.prototype.constructor = Sub` or `obj.toString = …`
  // would throw on frozen prototypes. These members become accessors whose
  // setter defines the property on the assigned object instead.
  const tamed = [
    "constructor", "toString", "toLocaleString", "valueOf", "hasOwnProperty", "isPrototypeOf",
    "propertyIsEnumerable", "toJSON",
  ];
  const tame = (proto) => {
    for (const name of tamed) {
      const d = Object.getOwnPropertyDescriptor(proto, name);
      if (!d || !("value" in d) || !d.writable) continue;
      const value = d.value;
      Object.defineProperty(proto, name, {
        get() { return value; },
        set(v) {
          if (this === proto) throw new TypeError(`Cannot assign to read only property '${name}'`);
          Object.defineProperty(this, name, { value: v, writable: true, enumerable: true, configurable: true });
        },
        enumerable: d.enumerable,
        configurable: false,
      });
    }
  };
  // Error.prototype stays writable: subclasses assign `this.name`.
  for (const proto of [
    Object.prototype, Array.prototype, Function.prototype, String.prototype, Number.prototype,
    Boolean.prototype, Symbol.prototype, RegExp.prototype, Promise.prototype, Map.prototype,
    Set.prototype, WeakMap.prototype, WeakSet.prototype, Date.prototype,
    Object.getPrototypeOf(Uint8Array.prototype),
  ]) {
    tame(proto);
    Object.freeze(proto);
  }
})();
