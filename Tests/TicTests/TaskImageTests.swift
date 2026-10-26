import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Tic

// MARK: - Fixtures

/// A test bitmap: red over the top half, blue over the bottom — so a crop's orientation is checkable.
private func makeImage(width: Int = 100, height: Int = 50) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))   // CG's y is up
    return context.makeImage()!
}

private func encode(_ image: CGImage, as type: UTType) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

private func imageType(_ data: Data) -> String? {
    CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceGetType($0) as String? }
}

/// The image averaged down to one pixel, as (red, blue).
private func averageColor(_ image: CGImage) -> (red: UInt8, blue: UInt8) {
    var pixel = [UInt8](repeating: 0, count: 4)
    pixel.withUnsafeMutableBytes { bytes in
        let context = CGContext(
            data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    return (pixel[0], pixel[2])
}

private func firstCrops(_ db: AppDatabase, _ noteId: UUID) async throws -> [UUID: CGRect] {
    for try await crops in db.observeTaskImageCrops(noteId: noteId) { return crops }
    return [:]
}

// MARK: - Pure helpers

@Suite("TaskImage")
struct TaskImageTests {
    @Test("PNG is stored as-is; other formats are re-encoded as PNG; non-images are rejected")
    func normalizedData() throws {
        let png = encode(makeImage(), as: .png)
        #expect(TaskImage.normalizedData(png) == png)

        let converted = try #require(TaskImage.normalizedData(encode(makeImage(), as: .tiff)))
        #expect(imageType(converted) == UTType.png.identifier)

        #expect(TaskImage.normalizedData(Data("not an image".utf8)) == nil)
    }

    @Test("the thumbnail is downsampled to the max pixel size, keeping the aspect ratio")
    func thumbnail() throws {
        let data = encode(makeImage(width: 400, height: 200), as: .png)
        let thumbnail = try #require(TaskImage.thumbnail(data, maxPixelSize: 100))
        #expect(thumbnail.width == 100)
        #expect(thumbnail.height == 50)
    }

    @Test("a normalised crop maps onto pixels with a top-left origin (no flip)")
    func croppedOrientation() throws {
        let image = makeImage(width: 100, height: 50)
        let top = try #require(TaskImage.cropped(image, to: CGRect(x: 0, y: 0, width: 0.5, height: 0.5)))
        #expect(top.width == 50 && top.height == 25)
        #expect(averageColor(top) == (255, 0))       // the top half is the red one

        let bottom = try #require(TaskImage.cropped(image, to: CGRect(x: 0, y: 0.5, width: 1, height: 0.5)))
        #expect(averageColor(bottom) == (0, 255))
    }

    @Test("an image fits the height cap, or the width when that's the tighter limit")
    func fittedSize() {
        #expect(TaskImage.fittedSize(aspect: 0.5, maxWidth: 600, maxHeight: 200) == CGSize(width: 100, height: 200))
        #expect(TaskImage.fittedSize(aspect: 4, maxWidth: 400, maxHeight: 200) == CGSize(width: 400, height: 100))
        #expect(TaskImage.fittedSize(aspect: 2, maxWidth: .infinity, maxHeight: 200) == CGSize(width: 400, height: 200))
    }

    @Test("dragging a corner moves only that corner, clamped to the image")
    func draggingCorner() {
        let crop = TaskImage.dragging(TaskImage.fullCrop, corner: .topLeading, by: CGSize(width: 0.25, height: 0.5))
        #expect(crop == CGRect(x: 0.25, y: 0.5, width: 0.75, height: 0.5))   // bottom-trailing stays put

        let outward = TaskImage.dragging(crop, corner: .topLeading, by: CGSize(width: -1, height: -1))
        #expect(outward == TaskImage.fullCrop)
    }

    @Test("a corner can't collapse the crop below the minimum side")
    func draggingMinimumSize() {
        let crop = TaskImage.dragging(TaskImage.fullCrop, corner: .bottomTrailing, by: CGSize(width: -2, height: -2))
        #expect(crop == CGRect(x: 0, y: 0, width: TaskImage.minCropSide, height: TaskImage.minCropSide))
    }

    @Test("sliding keeps the crop's size and keeps it inside the image")
    func movingCrop() {
        let crop = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        #expect(TaskImage.moving(crop, by: CGSize(width: 0.125, height: -0.125))
            == CGRect(x: 0.375, y: 0.125, width: 0.5, height: 0.5))
        #expect(TaskImage.moving(crop, by: CGSize(width: 5, height: -5)) == CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
    }

    @Test("the preview file is the cropped image as PNG — the stored bytes themselves when uncropped")
    func previewFile() throws {
        let png = encode(makeImage(width: 100, height: 50), as: .png)

        let full = try #require(TaskImage.writePreviewFile(png, crop: TaskImage.fullCrop))
        #expect(try Data(contentsOf: full) == png)

        let url = try #require(TaskImage.writePreviewFile(png, crop: CGRect(x: 0, y: 0, width: 0.5, height: 0.5)))
        #expect(url != full)   // a fresh file each time, so Quick Look never shows a stale crop
        let image = try #require(TaskImage.thumbnail(try Data(contentsOf: url), maxPixelSize: 1000))
        #expect(image.width == 50 && image.height == 25)
    }
}

// MARK: - Paste routing

@MainActor
@Suite("Pasting images")
struct PasteImageTests {
    /// A private, throwaway pasteboard, so the tests never touch the user's clipboard.
    private func withPasteboard(_ body: (NSPasteboard) throws -> Void) rethrows {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("tic.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        try body(pasteboard)
    }

    @Test("image data on its own pastes as an image")
    func imageData() throws {
        try withPasteboard { pasteboard in
            pasteboard.setData(encode(makeImage(), as: .tiff), forType: .tiff)
            #expect(pasteboard.hasPastableImage)
            let data = try #require(pasteboard.pastableImageData())
            #expect(imageType(data) == UTType.png.identifier)
        }
    }

    @Test("image data with plain text alongside pastes as text")
    func textWins() {
        withPasteboard { pasteboard in
            pasteboard.setData(encode(makeImage(), as: .png), forType: .png)
            pasteboard.setString("hello", forType: .string)
            #expect(!pasteboard.hasPastableImage)
            #expect(pasteboard.pastableImageData() == nil)
        }
    }

    @Test("an image file pastes as an image even with its name on the clipboard as text")
    func imageFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tic-\(UUID().uuidString).png")
        try encode(makeImage(), as: .png).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try withPasteboard { pasteboard in
            pasteboard.writeObjects([url as NSURL, url.lastPathComponent as NSString])
            #expect(pasteboard.hasPastableImage)
            let data = try #require(pasteboard.pastableImageData())
            #expect(!data.isEmpty)
        }
    }

    @Test("a non-image file pastes as text")
    func nonImageFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tic-\(UUID().uuidString).txt")
        try Data("hi".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        withPasteboard { pasteboard in
            pasteboard.writeObjects([url as NSURL])
            #expect(!pasteboard.hasPastableImage)
            #expect(pasteboard.pastableImageData() == nil)
        }
    }

    @Test("with nothing being edited, Paste travels past the SwiftUI hosting view to the note panel")
    func pasteReachesPanel() {
        _ = NSApplication.shared
        let panel = NotePanel(note: Note(), content: AnyView(Color.clear))
        var responder: NSResponder? = panel.contentView
        while let current = responder, !current.responds(to: #selector(NSText.paste(_:))) {
            responder = current.nextResponder
        }
        #expect(responder === panel)
    }
}

// MARK: - Storage

@Suite("Task images in the database")
struct TaskImageDatabaseTests {
    private func makeTaskWithImage() async throws -> (AppDatabase, Note, TaskItem, Data) {
        let db = try AppDatabase.makeInMemory()
        let note = Note()
        try await db.insert(note)
        let task = TaskItem(noteId: note.id)
        let png = encode(makeImage(), as: .png)
        try await db.insertTask(task, imageData: png)
        return (db, note, task, png)
    }

    @Test("a task inserted with an image stores the bytes and starts uncropped")
    func insertWithImage() async throws {
        let (db, note, task, png) = try await makeTaskWithImage()
        #expect(try await db.taskImageData(taskId: task.id) == png)
        #expect(try await firstCrops(db, note.id) == [task.id: TaskImage.fullCrop])
    }

    @Test("a whole-record task text commit leaves the image and its crop untouched")
    func textCommitKeepsImage() async throws {
        let (db, note, task, png) = try await makeTaskWithImage()
        let crop = CGRect(x: 0.25, y: 0, width: 0.5, height: 1)
        try await db.updateTaskImageCrop(taskId: task.id, crop: crop)
        var captioned = task
        captioned.text = "caption"
        try await db.update(captioned)
        #expect(try await db.taskImageData(taskId: task.id) == png)
        #expect(try await firstCrops(db, note.id) == [task.id: crop])
    }

    @Test("replacing an image resets its crop")
    func replaceResetsCrop() async throws {
        let (db, note, task, _) = try await makeTaskWithImage()
        try await db.updateTaskImageCrop(taskId: task.id, crop: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        let replacement = encode(makeImage(width: 10, height: 10), as: .png)
        try await db.setTaskImage(taskId: task.id, data: replacement)
        #expect(try await db.taskImageData(taskId: task.id) == replacement)
        #expect(try await firstCrops(db, note.id) == [task.id: TaskImage.fullCrop])
    }

    @Test("removing an image keeps its task")
    func deleteImageKeepsTask() async throws {
        let (db, note, task, _) = try await makeTaskWithImage()
        try await db.deleteTaskImage(taskId: task.id)
        #expect(try await db.taskImageData(taskId: task.id) == nil)
        #expect(try await db.tasks(noteId: note.id).map(\.id) == [task.id])
    }

    @Test("deleting a note cascades to its task images")
    func cascade() async throws {
        let (db, note, task, _) = try await makeTaskWithImage()
        try await db.deleteNote(id: note.id)
        #expect(try await db.taskImageData(taskId: task.id) == nil)
    }
}

// MARK: - Image layout

@MainActor
@Suite("Image layout")
struct TaskImageLayoutTests {
    /// The laid-out size of a task image offered `width` (and unlimited height, as in the note's list).
    private func layoutSize(imageWidth: Int, imageHeight: Int, offered width: CGFloat) -> CGSize? {
        let view = TaskImageView(
            image: makeImage(width: imageWidth, height: imageHeight), crop: TaskImage.fullCrop,
            theme: NoteTheme(color: .yellow, surface: .solid)
        )
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        renderer.scale = 1
        return renderer.cgImage.map { CGSize(width: $0.width, height: $0.height) }
    }

    @Test("the image view is exactly the picture's size, not the row's width (so its hover buttons sit on it)")
    func sizedToThePicture() {
        #expect(layoutSize(imageWidth: 100, imageHeight: 50, offered: 600) == CGSize(width: 400, height: 200))
        #expect(layoutSize(imageWidth: 100, imageHeight: 200, offered: 600) == CGSize(width: 100, height: 200))
        #expect(layoutSize(imageWidth: 400, imageHeight: 100, offered: 200) == CGSize(width: 200, height: 50))
    }
}

// MARK: - Crop mode input

/// Crop mode's AppKit input view, driven with real `NSEvent`s — the mouse-up and keyboard handling that
/// the earlier SwiftUI gesture/focus version got wrong in the live app.
@MainActor
@Suite("Crop mode input")
struct CropTrackingViewTests {
    private final class Recorder {
        var crops: [CGRect] = []
        var done = 0
        var cancelled = 0
    }

    /// A 200×100 crop view as a window's content, reporting into a recorder.
    private func makeView(crop: CGRect = TaskImage.fullCrop) -> (NSWindow, CropTrackingView, Recorder) {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let view = CropTrackingView()
        let recorder = Recorder()
        view.crop = crop
        view.onChange = { recorder.crops.append($0) }
        view.onDone = { recorder.done += 1 }
        view.onCancel = { recorder.cancelled += 1 }
        window.contentView = view
        return (window, view, recorder)
    }

    /// A mouse event at `point` in the view's own (top-left origin) coordinates.
    private func mouse(_ type: NSEvent.EventType, _ point: CGPoint, _ view: NSView) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: view.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }

    private func key(_ code: UInt16, _ view: NSView) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: view.window!.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: code
        )!
    }

    @Test("dragging a corner resizes from where the drag began, and stops at mouse-up")
    func cornerDragEndsOnMouseUp() {
        let (_, view, recorder) = makeView()
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 2, y: 2), view))   // near the top-leading corner
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 52, y: 27), view))
        #expect(recorder.crops == [CGRect(x: 0.25, y: 0.25, width: 0.75, height: 0.75)])

        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 52, y: 27), view))
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 150, y: 80), view))
        #expect(recorder.crops.count == 1)   // released: nothing follows the pointer any more
    }

    @Test("dragging away from the corners slides the crop")
    func slide() {
        let (_, view, recorder) = makeView(crop: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 100, y: 50), view))
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 125, y: 50), view))
        #expect(recorder.crops == [CGRect(x: 0.375, y: 0.25, width: 0.5, height: 0.5)])
    }

    @Test("crop mode takes the keyboard: Return keeps, Escape cancels, clicking away keeps")
    func keysAndClickAway() {
        let (window, view, recorder) = makeView()
        #expect(window.firstResponder === view)

        view.keyDown(with: key(36, view))
        #expect(recorder.done == 1)
        view.keyDown(with: key(53, view))
        #expect(recorder.cancelled == 1)

        window.makeFirstResponder(nil)   // what clicking the list background does
        #expect(recorder.done == 2)
    }
}

// MARK: - Image window

@MainActor
@Suite("Image window")
struct ImageWindowTests {
    @Test("the image starts fitted; ⌘= / ⌘- zoom in and out; ⌘0 fits it again")
    func keyboardZoom() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let view = ZoomScrollView()
        // Pin overlay scroll bars: legacy ones (a mouse, "Always show scroll bars", or another test's
        // synthetic mouse events flipping the process-wide preference) take width and shift the fit.
        view.scrollerStyle = .overlay
        window.contentView = view
        view.show(makeImage(width: 400, height: 100))
        let fitted = view.magnification
        #expect(fitted > 0 && fitted <= 0.5)   // 400pt wide into ≤200pt

        func press(_ key: String) -> Bool {
            view.performKeyEquivalent(with: NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0
            )!)
        }
        #expect(press("="))
        #expect(abs(view.magnification - fitted * 1.25) < 0.001)
        #expect(press("-"))
        #expect(press("-"))
        #expect(abs(view.magnification - fitted / 1.25) < 0.001)
        #expect(press("0"))
        #expect(abs(view.magnification - fitted) < 0.001)
        #expect(!press("k"))   // other ⌘ shortcuts pass through
    }

    @Test("Escape and ⌘W close the image window")
    func closeKeys() {
        _ = NSApplication.shared
        for (characters, flags, code) in [("\u{1b}", NSEvent.ModifierFlags(), UInt16(53)), ("w", .command, UInt16(13))] {
            let window = ImageWindow()
            window.orderFront(nil)
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
            )!
            #expect(window.performKeyEquivalent(with: event))
            #expect(!window.isVisible)
        }
    }
}

// MARK: - Controller

@MainActor
@Suite("NoteController images")
struct NoteControllerImageTests {
    private func makeController() async throws -> NoteController {
        let db = try AppDatabase.makeInMemory()
        let note = Note()
        try await db.insert(note)
        return NoteController(note: note, database: db)
    }

    @Test("a pasted image-only task is kept when its blank text is committed")
    func imageOnlyTaskSurvivesBlankCommit() async throws {
        let c = try await makeController()
        c.addTask("", imageData: encode(makeImage(), as: .png))
        let task = try #require(c.tasks.first)
        #expect(c.imageCrops[task.id] == TaskImage.fullCrop)

        c.commitText(task, "   ")
        #expect(c.tasks.map(\.id) == [task.id])
    }

    @Test("a blank task with no image is still never added")
    func blankWithoutImageIgnored() async throws {
        let c = try await makeController()
        c.addTask("   ")
        #expect(c.tasks.isEmpty)
    }

    @Test("pasting onto a blank new row saves it from the blank-row cleanup")
    func attachKeepsBlankRow() async throws {
        let c = try await makeController()
        c.addTask("Heading")
        let heading = try #require(c.tasks.first)
        let id = try #require(c.addSubtask(under: heading))
        let row = try #require(c.tasks.first { $0.id == id })

        c.attachImage(encode(makeImage(), as: .png), to: row)
        c.commitText(row, "")
        #expect(c.tasks.contains { $0.id == id })
    }

    @Test("setCrop changes an image's crop; tasks without an image are ignored")
    func setCrop() async throws {
        let c = try await makeController()
        c.addTask("", imageData: encode(makeImage(), as: .png))
        c.addTask("plain")
        let crop = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        c.setCrop(crop, for: c.tasks[0])
        c.setCrop(crop, for: c.tasks[1])
        #expect(c.imageCrops == [c.tasks[0].id: crop])
    }

    @Test("a staged image waits in the quick-add, then goes into the task Return adds")
    func stagedImage() async throws {
        let c = try await makeController()
        let png = encode(makeImage(), as: .png)
        c.stageImage(png)
        #expect(c.tasks.isEmpty)   // nothing is added until Return
        #expect(c.pendingImage == png)
        #expect(c.quickAddFocusRequest == 1)

        c.addTaskFromQuickAdd("Caption", level: 0)
        let task = try #require(c.tasks.first)
        #expect(task.text == "Caption")
        #expect(c.imageCrops[task.id] == TaskImage.fullCrop)
        #expect(c.pendingImage == nil)
    }

    @Test("a discarded staged image adds nothing")
    func discardedStagedImage() async throws {
        let c = try await makeController()
        c.stageImage(encode(makeImage(), as: .png))
        c.discardPendingImage()
        c.addTaskFromQuickAdd("", level: 0)
        #expect(c.tasks.isEmpty)
        #expect(c.pendingImage == nil)
    }

    @Test("removing the image of an image-only task removes the task; a captioned task keeps its text")
    func removeImage() async throws {
        let c = try await makeController()
        let png = encode(makeImage(), as: .png)
        c.addTask("", imageData: png)
        c.addTask("Captioned", imageData: png)
        let (imageOnly, captioned) = (c.tasks[0], c.tasks[1])

        c.removeImage(from: imageOnly)
        c.removeImage(from: captioned)
        #expect(c.tasks.map(\.text) == ["Captioned"])
        #expect(c.imageCrops.isEmpty)
    }
}
