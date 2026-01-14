#!/usr/bin/env node
/**
 * patch-host-js.js - Patches emscripten's generated host.js for Roc/Zig WASM compatibility
 *
 * Emscripten's JS runtime expects certain exports from the WASM module that Zig/Roc
 * doesn't produce. This script injects stub implementations directly into host.js
 * during the build process, ensuring they're available before any code tries to use them.
 *
 * Usage: node patch-host-js.js <input-host.js> <output-host.js>
 */

const fs = require('fs');
const path = require('path');

// GL functions that need aliases (Roc imports glFoo, emscripten exports emscripten_glFoo)
const GL_FUNCTIONS = [
    'glActiveTexture', 'glAttachShader', 'glBindAttribLocation', 'glBindBuffer',
    'glBindFramebuffer', 'glBindRenderbuffer', 'glBindTexture', 'glBlendEquation',
    'glBlendEquationSeparate', 'glBlendFunc', 'glBlendFuncSeparate', 'glBufferData',
    'glBufferSubData', 'glCheckFramebufferStatus', 'glClear', 'glClearColor',
    'glClearDepthf', 'glColorMask', 'glCompileShader', 'glCompressedTexImage2D',
    'glCreateProgram', 'glCreateShader', 'glCullFace', 'glDeleteBuffers',
    'glDeleteFramebuffers', 'glDeleteProgram', 'glDeleteRenderbuffers', 'glDeleteShader',
    'glDeleteTextures', 'glDepthFunc', 'glDepthMask', 'glDetachShader', 'glDisable',
    'glDisableVertexAttribArray', 'glDrawArrays', 'glDrawElements', 'glEnable',
    'glEnableVertexAttribArray', 'glFramebufferRenderbuffer', 'glFramebufferTexture2D',
    'glFrontFace', 'glGenBuffers', 'glGenerateMipmap', 'glGenFramebuffers',
    'glGenRenderbuffers', 'glGenTextures', 'glGetAttribLocation', 'glGetError',
    'glGetFloatv', 'glGetFramebufferAttachmentParameteriv', 'glGetProgramInfoLog',
    'glGetProgramiv', 'glGetShaderInfoLog', 'glGetShaderiv', 'glGetString',
    'glGetUniformLocation', 'glLineWidth', 'glLinkProgram', 'glPixelStorei',
    'glReadPixels', 'glRenderbufferStorage', 'glScissor', 'glShaderSource',
    'glTexImage2D', 'glTexParameterf', 'glTexParameteri', 'glTexSubImage2D',
    'glUniform1fv', 'glUniform1i', 'glUniform1iv', 'glUniform2fv', 'glUniform2iv',
    'glUniform3fv', 'glUniform3iv', 'glUniform4f', 'glUniform4fv', 'glUniform4iv',
    'glUniformMatrix4fv', 'glUseProgram', 'glVertexAttrib1fv', 'glVertexAttrib2fv',
    'glVertexAttrib3fv', 'glVertexAttrib4fv', 'glVertexAttribPointer', 'glViewport'
];

// Code to inject after wasmExports is set (after Asyncify instrumentation)
const EMSCRIPTEN_STUBS = `
    // === ROC/ZIG WASM COMPATIBILITY STUBS ===
    // Injected by patch-host-js.js
    // These provide emscripten-internal functions that Zig/Roc WASM doesn't export

    (function() {
        // Stack management stubs
        if (!wasmExports.emscripten_stack_init) {
            wasmExports.emscripten_stack_init = function() {};
        }
        if (!wasmExports.emscripten_stack_get_free) {
            wasmExports.emscripten_stack_get_free = function() { return 65536; };
        }
        if (!wasmExports.emscripten_stack_get_base) {
            wasmExports.emscripten_stack_get_base = function() {
                return wasmExports.memory ? wasmExports.memory.buffer.byteLength : 0;
            };
        }
        if (!wasmExports.emscripten_stack_get_end) {
            wasmExports.emscripten_stack_get_end = function() { return 0; };
        }
        if (!wasmExports._emscripten_stack_restore) {
            wasmExports._emscripten_stack_restore = function(val) {};
        }
        if (!wasmExports._emscripten_stack_alloc) {
            wasmExports._emscripten_stack_alloc = function(size) {
                return wasmExports._malloc ? wasmExports._malloc(size) : 0;
            };
        }
        if (!wasmExports.emscripten_stack_get_current) {
            wasmExports.emscripten_stack_get_current = function() { return 65536; };
        }

        // Asyncify stubs (Zig doesn't use asyncify)
        if (!wasmExports.asyncify_start_unwind) {
            wasmExports.asyncify_start_unwind = function(data) {};
        }
        if (!wasmExports.asyncify_stop_unwind) {
            wasmExports.asyncify_stop_unwind = function() {};
        }
        if (!wasmExports.asyncify_start_rewind) {
            wasmExports.asyncify_start_rewind = function(data) {};
        }
        if (!wasmExports.asyncify_stop_rewind) {
            wasmExports.asyncify_stop_rewind = function() {};
        }

        // dynCall stubs - emscripten uses these to invoke function pointers from JS
        // The Roc WASM exports __indirect_function_table which we use to call functions
        var table = wasmExports.__indirect_function_table;
        if (table) {
            // void signatures
            if (!wasmExports.dynCall_v) {
                wasmExports.dynCall_v = function(index) { return table.get(index)(); };
            }
            if (!wasmExports.dynCall_vi) {
                wasmExports.dynCall_vi = function(index, a1) { return table.get(index)(a1); };
            }
            if (!wasmExports.dynCall_vii) {
                wasmExports.dynCall_vii = function(index, a1, a2) { return table.get(index)(a1, a2); };
            }
            if (!wasmExports.dynCall_viii) {
                wasmExports.dynCall_viii = function(index, a1, a2, a3) { return table.get(index)(a1, a2, a3); };
            }
            if (!wasmExports.dynCall_viiii) {
                wasmExports.dynCall_viiii = function(index, a1, a2, a3, a4) { return table.get(index)(a1, a2, a3, a4); };
            }
            if (!wasmExports.dynCall_viiiii) {
                wasmExports.dynCall_viiiii = function(index, a1, a2, a3, a4, a5) { return table.get(index)(a1, a2, a3, a4, a5); };
            }
            if (!wasmExports.dynCall_viiiiii) {
                wasmExports.dynCall_viiiiii = function(index, a1, a2, a3, a4, a5, a6) { return table.get(index)(a1, a2, a3, a4, a5, a6); };
            }
            if (!wasmExports.dynCall_viiiiiii) {
                wasmExports.dynCall_viiiiiii = function(index, a1, a2, a3, a4, a5, a6, a7) { return table.get(index)(a1, a2, a3, a4, a5, a6, a7); };
            }

            // void with double args (for cursor position callbacks)
            if (!wasmExports.dynCall_vidd) {
                wasmExports.dynCall_vidd = function(index, a1, a2, a3) { return table.get(index)(a1, a2, a3); };
            }
            if (!wasmExports.dynCall_viff) {
                wasmExports.dynCall_viff = function(index, a1, a2, a3) { return table.get(index)(a1, a2, a3); };
            }
            if (!wasmExports.dynCall_vfff) {
                wasmExports.dynCall_vfff = function(index, a1, a2, a3) { return table.get(index)(a1, a2, a3); };
            }
            if (!wasmExports.dynCall_vffff) {
                wasmExports.dynCall_vffff = function(index, a1, a2, a3, a4) { return table.get(index)(a1, a2, a3, a4); };
            }

            // int return signatures
            if (!wasmExports.dynCall_i) {
                wasmExports.dynCall_i = function(index) { return table.get(index)(); };
            }
            if (!wasmExports.dynCall_ii) {
                wasmExports.dynCall_ii = function(index, a1) { return table.get(index)(a1); };
            }
            if (!wasmExports.dynCall_iii) {
                wasmExports.dynCall_iii = function(index, a1, a2) { return table.get(index)(a1, a2); };
            }
            if (!wasmExports.dynCall_iiii) {
                wasmExports.dynCall_iiii = function(index, a1, a2, a3) { return table.get(index)(a1, a2, a3); };
            }
            if (!wasmExports.dynCall_iiiii) {
                wasmExports.dynCall_iiiii = function(index, a1, a2, a3, a4) { return table.get(index)(a1, a2, a3, a4); };
            }
        }

        console.log('[patch-host-js] Injected emscripten compatibility stubs');
    })();
    // === END ROC/ZIG WASM COMPATIBILITY STUBS ===
`;

// Roc platform functions to add to wasmImports
const ROC_FUNCTIONS = `
// Roc platform functions for memory allocation and debugging
function _roc_alloc(size, alignment) { return _malloc(size); }
function _roc_dealloc(ptr, alignment) { _free(ptr); }
function _roc_realloc(ptr, new_size, old_size, alignment) { return _realloc(ptr, new_size); }
function _roc_dbg(loc_ptr, loc_len, msg_ptr, msg_len) {
    var loc = UTF8ToString(loc_ptr, loc_len);
    var msg = UTF8ToString(msg_ptr, msg_len);
    console.log("[dbg] " + loc + ": " + msg);
}
function _roc_expect_failed(ptr, len) {
    var msg = UTF8ToString(ptr, len);
    console.error("[expect failed] " + msg);
}
function _roc_panic(ptr, len) {
    var msg = UTF8ToString(ptr, len);
    console.error("[panic] " + msg);
    throw new Error("Roc panic: " + msg);
}
function _glfwGetProcAddress(name) { return 0; }
`;

const ROC_WASM_IMPORTS = `
  roc_alloc: _roc_alloc,
  roc_dealloc: _roc_dealloc,
  roc_realloc: _roc_realloc,
  roc_dbg: _roc_dbg,
  roc_expect_failed: _roc_expect_failed,
  roc_panic: _roc_panic,
  glfwGetProcAddress: _glfwGetProcAddress,`;

function main() {
    const args = process.argv.slice(2);
    if (args.length !== 2) {
        console.error('Usage: node patch-host-js.js <input-host.js> <output-host.js>');
        process.exit(1);
    }

    const inputPath = args[0];
    const outputPath = args[1];

    console.log(`[patch-host-js] Reading ${inputPath}...`);
    let code = fs.readFileSync(inputPath, 'utf8');

    // 0. Disable checkStackCookie - Zig doesn't write stack cookies
    // Add early return at the start of the function
    const stackCookiePattern = 'function checkStackCookie() {';
    if (code.includes(stackCookiePattern)) {
        code = code.replace(
            stackCookiePattern,
            'function checkStackCookie() { return; /* disabled for Zig wasm */'
        );
        console.log('[patch-host-js] Disabled checkStackCookie');
    }

    // 0b. Fix findEventTarget to handle empty strings by defaulting to canvas
    // Raylib passes empty string as target, which causes querySelector('') to fail
    // We need to patch AFTER maybeCStringToJsString converts the pointer to a string
    const findEventTargetQuerySelector = "document.querySelector(target)";
    if (code.includes(findEventTargetQuerySelector)) {
        code = code.replace(
            findEventTargetQuerySelector,
            "(target === '' ? Module['canvas'] : document.querySelector(target))"
        );
        console.log('[patch-host-js] Patched findEventTarget for empty targets');
    }

    // 0c. Debug updateMemoryViews to see what's happening with memory
    const updateMemoryPattern = 'function updateMemoryViews() {';
    if (code.includes(updateMemoryPattern)) {
        code = code.replace(
            updateMemoryPattern,
            `function updateMemoryViews() {
  console.log('[updateMemoryViews] wasmMemory:', wasmMemory);
  console.log('[updateMemoryViews] wasmMemory.buffer:', wasmMemory ? wasmMemory.buffer : 'N/A');
  console.log('[updateMemoryViews] buffer.byteLength:', wasmMemory && wasmMemory.buffer ? wasmMemory.buffer.byteLength : 'N/A');`
        );
        console.log('[patch-host-js] Added updateMemoryViews debugging');
    }

    // 0d. Debug and fix GL.getSource for HEAPU32 issues
    // The issue is that HEAPU32[index] can return undefined if index is out of bounds
    const getSourcePattern = 'getSource:(shader, count, string, length) => {';
    if (code.includes(getSourcePattern)) {
        code = code.replace(
            getSourcePattern,
            `getSource:(shader, count, string, length) => {
        // Debug logging
        if (typeof string !== 'number' || string < 0 || string >= HEAPU8.length) {
          console.error('[GL.getSource] Invalid string pointer:', string, 'HEAPU8.length:', HEAPU8.length, 'wasmMemory:', wasmMemory);
          return '';
        }`
        );
        console.log('[patch-host-js] Added GL.getSource debugging');
    }

    // 1. Inject emscripten stubs after Asyncify instrumentation
    const asyncifyPattern = 'wasmExports = Asyncify.instrumentWasmExports(wasmExports);';
    if (code.includes(asyncifyPattern)) {
        code = code.replace(
            asyncifyPattern,
            asyncifyPattern + '\n' + EMSCRIPTEN_STUBS
        );
        console.log('[patch-host-js] Injected emscripten stubs after Asyncify instrumentation');
    } else {
        // Fallback: inject after wasmExports = instance.exports
        const fallbackPattern = 'wasmExports = instance.exports;';
        if (code.includes(fallbackPattern)) {
            code = code.replace(
                fallbackPattern,
                fallbackPattern + '\n' + EMSCRIPTEN_STUBS
            );
            console.log('[patch-host-js] Injected emscripten stubs after instance.exports (fallback)');
        } else {
            console.error('[patch-host-js] ERROR: Could not find injection point for emscripten stubs');
        }
    }

    // 2. Add Roc function implementations before wasmImports
    const wasmImportsPattern = 'var wasmImports = {';
    if (code.includes(wasmImportsPattern)) {
        code = code.replace(
            wasmImportsPattern,
            ROC_FUNCTIONS + '\n' + wasmImportsPattern
        );
        console.log('[patch-host-js] Added Roc platform function implementations');
    }

    // 3. Add Roc functions to wasmImports object
    if (code.includes(wasmImportsPattern)) {
        code = code.replace(
            wasmImportsPattern,
            wasmImportsPattern + '\n' + ROC_WASM_IMPORTS
        );
        console.log('[patch-host-js] Added Roc functions to wasmImports');
    }

    // 4. Add GL function aliases (glFoo -> emscripten_glFoo)
    let glAliasCount = 0;
    for (const fn of GL_FUNCTIONS) {
        const emscriptenFn = `emscripten_${fn}`;
        const pattern = new RegExp(`(${emscriptenFn}: _${emscriptenFn},)`, 'g');
        if (code.includes(`${emscriptenFn}: _${emscriptenFn},`)) {
            code = code.replace(
                pattern,
                `$1\n  ${fn}: _${emscriptenFn},`
            );
            glAliasCount++;
        }
    }
    console.log(`[patch-host-js] Added ${glAliasCount} GL function aliases`);

    // 5. Write output
    console.log(`[patch-host-js] Writing ${outputPath}...`);
    fs.writeFileSync(outputPath, code);
    console.log('[patch-host-js] Done!');
}

main();
