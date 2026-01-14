// JavaScript library for Roc platform host
// These functions are imported by the WASM module

addToLibrary({
  js_console_log: function(ptr, len) {
    var text = UTF8ToString(ptr, len);
    console.log(text);
  },

  js_console_error: function(ptr, len) {
    var text = UTF8ToString(ptr, len);
    console.error(text);
  },

  // glfwGetProcAddress is not provided by emscripten's GLFW because WebGL
  // doesn't need explicit function pointer loading like desktop GL.
  // Return 0 (null) - WebGL functions are accessed directly through the context.
  glfwGetProcAddress: function(name) {
    return 0;
  },

  // Roc memory allocation - uses the wasm's exported malloc
  roc_alloc: function(size, alignment) {
    // Use the wasm's malloc export for allocation
    // alignment is ignored since malloc handles it
    return _malloc(size);
  },

  // Roc deallocation
  roc_dealloc: function(ptr, alignment) {
    _free(ptr);
  },

  // Roc reallocation
  roc_realloc: function(ptr, new_size, old_size, alignment) {
    return _realloc(ptr, new_size);
  },

  // Roc debug output
  roc_dbg: function(loc_ptr, loc_len, msg_ptr, msg_len) {
    var loc = UTF8ToString(loc_ptr, loc_len);
    var msg = UTF8ToString(msg_ptr, msg_len);
    console.log('[dbg] ' + loc + ': ' + msg);
  },

  // Roc expect (assertion)
  roc_expect_failed: function(ptr, len) {
    var msg = UTF8ToString(ptr, len);
    console.error('[expect failed] ' + msg);
  },

  // Roc panic
  roc_panic: function(ptr, len) {
    var msg = UTF8ToString(ptr, len);
    console.error('[panic] ' + msg);
    throw new Error('Roc panic: ' + msg);
  },
});
