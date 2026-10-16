// Load before a dart2wasm application that catches guest exceptions synchronously.
(() => {
  const key = Symbol.for('wasd.wasm.exceptionBridge');
  if (globalThis[key]) return;
  const capture = (action) => {
    try {
      return { ok: true, value: action() };
    } catch (error) {
      return { ok: false, error };
    }
  };
  Object.defineProperty(globalThis, key, {
    value: Object.freeze({
      invoke: (fn, args) => capture(() => Reflect.apply(fn, undefined, args)),
      construct: (ctor, args) => capture(() => Reflect.construct(ctor, args)),
    }),
  });
})();
