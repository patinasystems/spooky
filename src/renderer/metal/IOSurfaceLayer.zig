//! A wrapper around a CALayer with a utility method
//! for settings its `contents` to an IOSurface.
const IOSurfaceLayer = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const objc = @import("objc");
const macos = @import("macos");

const IOSurface = macos.iosurface.IOSurface;
const NativePresentation = @import("../NativePresentation.zig");

const log = std.log.scoped(.IOSurfaceLayer);

/// We subclass CALayer with a custom display handler, we only need
/// to make the subclass once, and then we can use it as a singleton.
var Subclass: ?objc.Class = null;

/// The underlying CALayer
layer: objc.Object,
allocator: Allocator,
presentation: *Presentation,

pub const PresentationCallback = *const fn (?*anyopaque, NativePresentation.Snapshot) void;
const Presentation = struct {
    tracker: NativePresentation.Tracker = .{},
    callback: ?PresentationCallback = null,
    context: ?*anyopaque = null,
};

pub fn init(alloc: Allocator) !IOSurfaceLayer {
    // The layer returned by `[CALayer layer]` is autoreleased, which means
    // that at the end of the current autorelease pool it will be deallocated
    // if it isn't retained, so we retain it here manually an extra time.
    const layer = (try getSubclass()).msgSend(
        objc.Object,
        objc.sel("layer"),
        .{},
    ).retain();
    errdefer layer.release();

    // The layer gravity is set to top-left so that the contents aren't
    // stretched during resize operations before a new frame has been drawn.
    layer.setProperty("contentsGravity", macos.animation.kCAGravityTopLeft);

    layer.setInstanceVariable("display_cb", .{ .value = null });
    layer.setInstanceVariable("display_ctx", .{ .value = null });
    const presentation = try alloc.create(Presentation);
    presentation.* = .{};
    layer.setInstanceVariable("presentation", objc.Object.fromId(@as(?*anyopaque, @ptrCast(presentation))));

    return .{ .layer = layer, .allocator = alloc, .presentation = presentation };
}

pub fn release(self: *IOSurfaceLayer) void {
    // The layer may be retained by the view after we release our reference.
    // Clear the callback first so that a later display pass can't access the
    // renderer that owned this wrapper after it has been freed.
    self.setDisplayCallback(null, null);
    // Queued completion blocks retain the layer, not this allocation. They
    // reread its nullable context on main and cannot call a destroyed surface.
    self.layer.setInstanceVariable("presentation", .{ .value = null });
    self.allocator.destroy(self.presentation);
    self.layer.release();
}

pub fn setPresentationCallback(self: *IOSurfaceLayer, callback: PresentationCallback, context: ?*anyopaque) void {
    self.presentation.callback = callback;
    self.presentation.context = context;
}

/// Sets the layer's `contents` to the provided IOSurface.
///
/// Makes sure to do so on the main thread to avoid visual artifacts.
pub inline fn setSurface(self: *IOSurfaceLayer, surface: *IOSurface, snapshot: NativePresentation.Snapshot) !void {
    self.enqueueSurface(surface, snapshot, true);
}

fn enqueueSurface(self: *IOSurfaceLayer, surface: *IOSurface, snapshot: NativePresentation.Snapshot, inline_if_main: bool) void {
    // We retain the surface to make sure it's not GC'd
    // before we can set it as the contents of the layer.
    //
    // We release in the callback after setting the contents.
    surface.retain();
    // NOTE: Since `self.layer` is passed as an `objc.c.id`, it's
    //       automatically retained when the block is copied, so we
    //       don't need to retain it ourselves like with the surface.

    var block = SetSurfaceBlock.init(.{
        .layer = self.layer.value,
        .surface = surface,
        .snapshot = snapshot,
    }, &setSurfaceCallback);

    // We check if we're on the main thread and run the block directly if so.
    const NSThread = objc.getClass("NSThread").?;
    if (inline_if_main and NSThread.msgSend(bool, "isMainThread", .{})) {
        setSurfaceCallback(&block);
    } else {
        // NOTE: The block will be copied when we pass it to dispatch_async,
        //       and then automatically be deallocated by the objc runtime
        //       once it's executed.

        macos.dispatch.dispatch_async(
            @ptrCast(macos.dispatch.queue.getMain()),
            @ptrCast(&block),
        );
    }
}

/// Sets the layer's `contents` to the provided IOSurface.
///
/// Does not ensure this happens on the main thread.
pub inline fn setSurfaceSync(self: *IOSurfaceLayer, surface: *IOSurface, snapshot: NativePresentation.Snapshot) void {
    // A synchronous resize draw holds the renderer's draw lock. It establishes
    // frame ordering but must not reenter AppKit/native APIs under that lock.
    if (!self.presentation.tracker.admit(snapshot, false).present) return;
    if (self.presentation.tracker.needsNotification(snapshot)) {
        // Native boundary frames must never become visible without their
        // AppKit handoff. Always enqueue, even on main: this caller holds the
        // draw lock and invoking native layout here could reenter the renderer.
        self.enqueueSurface(surface, snapshot, false);
        return;
    }
    self.layer.setProperty("contents", surface);
}

const SetSurfaceBlock = objc.Block(struct {
    layer: objc.c.id,
    surface: *IOSurface,
    snapshot: NativePresentation.Snapshot,
    deferred: bool = false,
}, .{}, void);

fn setSurfaceCallback(
    block: *const SetSurfaceBlock.Context,
) callconv(.c) void {
    const layer = objc.Object.fromId(block.layer);
    const surface: *IOSurface = block.surface;

    // See explanation of why we retain and release in `setSurface`.
    defer surface.release();

    // We check to see if the surface is the appropriate size for
    // the layer, if it's not then we discard it. This is because
    // asynchronously drawn frames can sometimes finish just after
    // a synchronously drawn frame during a resize, and if we don't
    // discard the improperly sized surface it creates jank.
    const bounds = layer.getProperty(macos.graphics.Rect, "bounds");
    const scale = layer.getProperty(f64, "contentsScale");
    const width: usize = @intFromFloat(bounds.size.width * scale);
    const height: usize = @intFromFloat(bounds.size.height * scale);
    if (width != surface.getWidth() or height != surface.getHeight()) {
        log.debug(
            "setSurfaceCallback(): surface is wrong size for layer, discarding. surface = {d}x{d}, layer = {d}x{d}",
            .{ surface.getWidth(), surface.getHeight(), width, height },
        );
        return;
    }

    const presentation: *Presentation = @ptrCast(@alignCast(layer.getInstanceVariable("presentation").value orelse return));
    if (block.snapshot.defer_prompt and !block.deferred) {
        // Completed output/erase and the next ready prompt can straddle a
        // PTY read. Retain at most one frame budget without another render.
        // Running output is never tagged; a newer prompt makes this stale.
        surface.retain();
        var delayed = SetSurfaceBlock.init(.{ .layer = block.layer, .surface = surface, .snapshot = block.snapshot, .deferred = true }, &setSurfaceCallback);
        dispatch_after(macos.dispatch.c.dispatch_time(macos.dispatch.c.DISPATCH_TIME_NOW, 16_666_667), @ptrCast(macos.dispatch.queue.getMain()), @ptrCast(&delayed));
        return;
    }
    const admission = presentation.tracker.admit(block.snapshot, true);
    if (!admission.present) return;

    // Native AppKit views can draw/flush while the callback lays them out.
    // Keep their backing-layer updates and this IOSurface replacement in one
    // explicit transaction, including any synchronous resize draw it causes.
    // Ordinary streaming frames retain the existing implicit transaction path.
    const transaction = objc.getClass("CATransaction").?;
    if (admission.notify) {
        transaction.msgSend(void, "begin", .{});
        transaction.msgSend(void, "setDisableActions:", .{true});
    }
    defer if (admission.notify) transaction.msgSend(void, "commit", .{});
    layer.setProperty("contents", surface);
    // The native visual handoff changes in this same main-thread transaction,
    // after the new pixels are attached; GPU completion alone is insufficient.
    if (admission.notify) if (presentation.callback) |callback|
        callback(presentation.context, block.snapshot);
}

pub const DisplayCallback = ?*align(8) const fn (?*anyopaque) void;

pub fn setDisplayCallback(
    self: *IOSurfaceLayer,
    display_cb: DisplayCallback,
    display_ctx: ?*anyopaque,
) void {
    self.layer.setInstanceVariable(
        "display_cb",
        objc.Object.fromId(@constCast(display_cb)),
    );
    self.layer.setInstanceVariable(
        "display_ctx",
        objc.Object.fromId(display_ctx),
    );
}

fn getSubclass() error{ObjCFailed}!objc.Class {
    if (Subclass) |c| return c;

    const CALayer =
        objc.getClass("CALayer") orelse return error.ObjCFailed;

    var subclass =
        objc.allocateClassPair(CALayer, "IOSurfaceLayer") orelse return error.ObjCFailed;
    errdefer objc.disposeClassPair(subclass);

    if (!subclass.addIvar("display_cb")) return error.ObjCFailed;
    if (!subclass.addIvar("display_ctx")) return error.ObjCFailed;
    if (!subclass.addIvar("presentation")) return error.ObjCFailed;

    subclass.replaceMethod("display", struct {
        fn display(target: objc.c.id, sel: objc.c.SEL) callconv(.c) void {
            _ = sel;
            const self = objc.Object.fromId(target);
            const display_cb: DisplayCallback = @ptrFromInt(@intFromPtr(
                self.getInstanceVariable("display_cb").value,
            ));
            if (display_cb) |cb| cb(
                @ptrCast(self.getInstanceVariable("display_ctx").value),
            );
        }
    }.display);

    // Disable all animations for this layer by returning null for all actions.
    subclass.replaceMethod("actionForKey:", struct {
        fn actionForKey(
            target: objc.c.id,
            sel: objc.c.SEL,
            key: objc.c.id,
        ) callconv(.c) objc.c.id {
            _ = target;
            _ = sel;
            _ = key;
            return objc.getClass("NSNull").?.msgSend(objc.c.id, "null", .{});
        }
    }.actionForKey);

    objc.registerClassPair(subclass);

    Subclass = subclass;

    return subclass;
}

// C import cannot translate Objective-C block typedefs. Same ABI as dispatch_async.
extern "c" fn dispatch_after(when: u64, queue: *anyopaque, block: *anyopaque) void;
