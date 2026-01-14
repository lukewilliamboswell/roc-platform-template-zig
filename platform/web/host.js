'use strict';

/**
 * host.js - Zero-allocation JavaScript runtime for Roc WASM platform
 *
 * Reads command buffer from WASM memory and renders to Canvas 2D.
 * All TypedArray views are created once at init and reused every frame.
 */

// =============================================================================
// WASM Imports (logging only - allocator is in Zig)
// =============================================================================

// Console log from WASM
function js_console_log(ptr, len) {
    const msg = new TextDecoder().decode(new Uint8Array(memory.buffer, ptr, len));
    console.log('[roc]', msg);
}

// Error throwing from WASM (for roc_panic - provides better stack traces than @panic)
function js_throw_error(ptr, len) {
    const msg = new TextDecoder().decode(new Uint8Array(memory.buffer, ptr, len));
    console.error('[roc_panic]', msg);
    throw new Error('[roc_panic] ' + msg);
}

// Color palette (matches Roc's Color type - alphabetical order)
const COLORS = [
    '#000000', // 0: Black
    '#0000ff', // 1: Blue
    '#505050', // 2: DarkGray
    '#808080', // 3: Gray
    '#00ff00', // 4: Green
    '#c0c0c0', // 5: LightGray
    '#ffa500', // 6: Orange
    '#ffc0cb', // 7: Pink
    '#800080', // 8: Purple
    '#f5f5f5', // 9: RayWhite
    '#ff0000', // 10: Red
    '#ffffff', // 11: White
    '#ffff00', // 12: Yellow
];

// Command type codes (must match Zig)
const CMD_RECT = 1;
const CMD_CIRCLE = 2;
const CMD_LINE = 3;
const CMD_TEXT = 4;

// Capacities (must match Zig)
const MAX_COMMANDS = 2048;
const MAX_RECTS = 1024;
const MAX_CIRCLES = 512;
const MAX_LINES = 512;
const MAX_TEXTS = 256;
const MAX_STRING_BYTES = 8192;

// Runtime state
let wasm = null;
let memory = null;
let ctx = null;
let canvas = null;

// Input state
let mouseX = 0;
let mouseY = 0;
let mouseButtons = 0;
let mouseWheel = 0;

// Command buffer pointer and offsets (populated from WASM exports)
let cmdBufferPtr = 0;
let OFFSETS = {};

// Cached TypedArray views (created once, reused every frame)
let cmdStream = null;
let rectX = null, rectY = null, rectW = null, rectH = null, rectColor = null;
let circleX = null, circleY = null, circleRadius = null, circleColor = null;
let lineX1 = null, lineY1 = null, lineX2 = null, lineY2 = null, lineColor = null;
let textX = null, textY = null, textSize = null, textColor = null;
let textStrOffset = null, textStrLen = null;
let stringBuffer = null;

// Text decoder (reused)
const decoder = new TextDecoder();

/**
 * Initialize the WASM module and canvas
 * @param {string} wasmPath - Path to the .wasm file
 * @param {string} canvasId - ID of the canvas element
 */
async function init(wasmPath = 'app.wasm', canvasId = 'canvas') {
    canvas = document.getElementById(canvasId);
    if (!canvas) {
        throw new Error(`Canvas element '${canvasId}' not found`);
    }
    ctx = canvas.getContext('2d');

    // Setup mouse tracking
    setupMouseTracking();

    // Load WASM
    console.log(`[host.js] Loading ${wasmPath}...`);

    // Provide imports for Zig host (allocator is in Zig, not JS)
    const imports = {
        env: {
            // Logging from Zig
            js_log_num: (num) => console.log('[WASM]', num),
            js_console_log,
            // Error throwing (replaces @panic for better debug info)
            js_throw_error,
        }
    };

    try {
        const response = await fetch(wasmPath);
        if (!response.ok) {
            throw new Error(`Failed to fetch ${wasmPath}: ${response.status}`);
        }
        const { instance } = await WebAssembly.instantiateStreaming(response, imports);
        wasm = instance.exports;
        memory = wasm.memory;

        console.log('[host.js] WASM loaded successfully');
        console.log('[host.js] Memory size:', memory.buffer.byteLength, 'bytes');
    } catch (e) {
        console.error('[host.js] Failed to load WASM:', e);
        throw e;
    }

    // Get buffer offsets from WASM exports
    populateOffsets();

    // Initialize app
    console.log('[host.js] Initializing app...');
    console.log('[host.js] Available WASM exports:', Object.keys(wasm));
    try {
        wasm._init();
        console.log('[host.js] _init completed successfully');
    } catch (e) {
        console.error('[host.js] _init failed:', e);
        throw e;
    }

    // Create TypedArray views (buffer address is stable after init)
    createBufferViews();

    console.log('[host.js] Starting render loop');
    requestAnimationFrame(frame);
}

/**
 * Setup mouse event listeners on canvas
 */
function setupMouseTracking() {
    canvas.addEventListener('mousemove', (e) => {
        const rect = canvas.getBoundingClientRect();
        mouseX = e.clientX - rect.left;
        mouseY = e.clientY - rect.top;
    });

    canvas.addEventListener('mousedown', (e) => {
        mouseButtons |= (1 << e.button);
        e.preventDefault();
    });

    canvas.addEventListener('mouseup', (e) => {
        mouseButtons &= ~(1 << e.button);
    });

    canvas.addEventListener('mouseleave', () => {
        mouseButtons = 0;
    });

    canvas.addEventListener('wheel', (e) => {
        mouseWheel = e.deltaY;
        e.preventDefault();
    }, { passive: false });

    canvas.addEventListener('contextmenu', (e) => e.preventDefault());

    // Prevent text selection when clicking on canvas
    canvas.style.userSelect = 'none';
}

/**
 * Populate OFFSETS object from WASM exported offset functions
 */
function populateOffsets() {
    cmdBufferPtr = wasm._get_cmd_buffer_ptr();

    OFFSETS = {
        has_clear: wasm._get_offset_has_clear(),
        clear_color: wasm._get_offset_clear_color(),
        cmd_stream: wasm._get_offset_cmd_stream(),
        cmd_count: wasm._get_offset_cmd_count(),
        rect_count: wasm._get_offset_rect_count(),
        rect_x: wasm._get_offset_rect_x(),
        rect_y: wasm._get_offset_rect_y(),
        rect_w: wasm._get_offset_rect_w(),
        rect_h: wasm._get_offset_rect_h(),
        rect_color: wasm._get_offset_rect_color(),
        circle_count: wasm._get_offset_circle_count(),
        circle_x: wasm._get_offset_circle_x(),
        circle_y: wasm._get_offset_circle_y(),
        circle_radius: wasm._get_offset_circle_radius(),
        circle_color: wasm._get_offset_circle_color(),
        line_count: wasm._get_offset_line_count(),
        line_x1: wasm._get_offset_line_x1(),
        line_y1: wasm._get_offset_line_y1(),
        line_x2: wasm._get_offset_line_x2(),
        line_y2: wasm._get_offset_line_y2(),
        line_color: wasm._get_offset_line_color(),
        text_count: wasm._get_offset_text_count(),
        text_x: wasm._get_offset_text_x(),
        text_y: wasm._get_offset_text_y(),
        text_size: wasm._get_offset_text_size(),
        text_color: wasm._get_offset_text_color(),
        text_str_offset: wasm._get_offset_text_str_offset(),
        text_str_len: wasm._get_offset_text_str_len(),
        string_buffer: wasm._get_offset_string_buffer(),
        string_buffer_len: wasm._get_offset_string_buffer_len(),
    };

    console.log('[host.js] Buffer offsets loaded:', OFFSETS);
}

// Track the current buffer to detect when memory grows
let currentBuffer = null;

/**
 * Refresh TypedArray views if memory has grown
 * Called each frame to handle memory.grow() invalidating views
 */
function refreshBufferViews() {
    if (memory.buffer !== currentBuffer) {
        createBufferViews();
    }
}

/**
 * Create TypedArray views into WASM memory
 * These are created once and reused every frame for zero allocation
 */
function createBufferViews() {
    const buf = memory.buffer;
    currentBuffer = buf; // Track current buffer
    const base = cmdBufferPtr;

    cmdStream = new Uint16Array(buf, base + OFFSETS.cmd_stream, MAX_COMMANDS);

    // Rectangle arrays
    rectX = new Float32Array(buf, base + OFFSETS.rect_x, MAX_RECTS);
    rectY = new Float32Array(buf, base + OFFSETS.rect_y, MAX_RECTS);
    rectW = new Float32Array(buf, base + OFFSETS.rect_w, MAX_RECTS);
    rectH = new Float32Array(buf, base + OFFSETS.rect_h, MAX_RECTS);
    rectColor = new Uint8Array(buf, base + OFFSETS.rect_color, MAX_RECTS);

    // Circle arrays
    circleX = new Float32Array(buf, base + OFFSETS.circle_x, MAX_CIRCLES);
    circleY = new Float32Array(buf, base + OFFSETS.circle_y, MAX_CIRCLES);
    circleRadius = new Float32Array(buf, base + OFFSETS.circle_radius, MAX_CIRCLES);
    circleColor = new Uint8Array(buf, base + OFFSETS.circle_color, MAX_CIRCLES);

    // Line arrays
    lineX1 = new Float32Array(buf, base + OFFSETS.line_x1, MAX_LINES);
    lineY1 = new Float32Array(buf, base + OFFSETS.line_y1, MAX_LINES);
    lineX2 = new Float32Array(buf, base + OFFSETS.line_x2, MAX_LINES);
    lineY2 = new Float32Array(buf, base + OFFSETS.line_y2, MAX_LINES);
    lineColor = new Uint8Array(buf, base + OFFSETS.line_color, MAX_LINES);

    // Text arrays
    textX = new Float32Array(buf, base + OFFSETS.text_x, MAX_TEXTS);
    textY = new Float32Array(buf, base + OFFSETS.text_y, MAX_TEXTS);
    textSize = new Int32Array(buf, base + OFFSETS.text_size, MAX_TEXTS);
    textColor = new Uint8Array(buf, base + OFFSETS.text_color, MAX_TEXTS);
    textStrOffset = new Uint16Array(buf, base + OFFSETS.text_str_offset, MAX_TEXTS);
    textStrLen = new Uint16Array(buf, base + OFFSETS.text_str_len, MAX_TEXTS);

    // String buffer
    stringBuffer = new Uint8Array(buf, base + OFFSETS.string_buffer, MAX_STRING_BYTES);

    console.log('[host.js] Buffer views created');
}

/**
 * Main frame loop - called by requestAnimationFrame
 */
function frame(timestamp) {
    // Call WASM frame function - fills command buffer
    wasm._frame(mouseX, mouseY, mouseButtons, mouseWheel);
    mouseWheel = 0; // Reset wheel after each frame

    // Recreate TypedArray views if memory has grown (buffer changes on grow)
    // This is necessary because memory.buffer becomes a new ArrayBuffer after grow()
    refreshBufferViews();

    // Render from command buffer
    render();

    // Continue loop
    requestAnimationFrame(frame);
}

/**
 * Render command buffer to canvas
 * NO allocations - reads directly from WASM memory via TypedArrays
 */
function render() {
    const view = new DataView(memory.buffer, cmdBufferPtr);

    // Handle clear (always first if present)
    const hasClear = view.getUint8(OFFSETS.has_clear) !== 0;
    if (hasClear) {
        const clearColorIdx = view.getUint8(OFFSETS.clear_color);
        ctx.fillStyle = COLORS[clearColorIdx] || '#000000';
        ctx.fillRect(0, 0, canvas.width, canvas.height);
    }

    // Get command count
    const cmdCount = view.getUint32(OFFSETS.cmd_count, true);

    // Iterate command stream in draw order - NO SORTING, NO ALLOCATION
    for (let c = 0; c < cmdCount; c++) {
        const cmd = cmdStream[c];
        const type = cmd >> 12;
        const idx = cmd & 0xFFF;

        switch (type) {
            case CMD_RECT:
                ctx.fillStyle = COLORS[rectColor[idx]] || '#000000';
                ctx.fillRect(rectX[idx], rectY[idx], rectW[idx], rectH[idx]);
                break;

            case CMD_CIRCLE:
                ctx.fillStyle = COLORS[circleColor[idx]] || '#000000';
                ctx.beginPath();
                ctx.arc(circleX[idx], circleY[idx], circleRadius[idx], 0, Math.PI * 2);
                ctx.fill();
                break;

            case CMD_LINE:
                ctx.strokeStyle = COLORS[lineColor[idx]] || '#000000';
                ctx.lineWidth = 1;
                ctx.beginPath();
                ctx.moveTo(lineX1[idx], lineY1[idx]);
                ctx.lineTo(lineX2[idx], lineY2[idx]);
                ctx.stroke();
                break;

            case CMD_TEXT:
                ctx.fillStyle = COLORS[textColor[idx]] || '#000000';
                ctx.font = `${textSize[idx]}px sans-serif`;
                const strOff = textStrOffset[idx];
                const strLen = textStrLen[idx];
                // TextDecoder is the only allocation - unavoidable for strings
                const str = decoder.decode(stringBuffer.subarray(strOff, strOff + strLen));
                ctx.fillText(str, textX[idx], textY[idx]);
                break;
        }
    }
}

// Export for use in HTML
window.RocHost = {
    init,
    // Expose for testing
    getWasm: () => wasm,
    getOffsets: () => OFFSETS,
    getCmdBufferPtr: () => cmdBufferPtr,
};
