import Foundation
import Testing
@testable import Tic

/// Choosing which lists sync, and images, through the same simulated Macs as `SyncSimulationTests`.
@MainActor
@Suite("Sync simulation: choosing lists")
struct SyncSharingTests {

    private func fileText(_ mac: SimMac) throws -> String {
        String(decoding: try Data(contentsOf: mac.ownFile), as: UTF8.self)
    }

    @Test("a list that doesn't sync never leaves its Mac, not even its title")
    func unsyncedStaysHome() async throws {
        let world = SyncWorld(); defer { world.cleanUp() }
        let work = try world.mac("Work MacBook"), home = try world.mac("Home iMac")
        let shared = try await work.newList("This week")
        let secret = try await work.newList("Surprise party", synced: false)
        try await work.add("Buy the cake", to: secret)
        try await world.syncAll()

        #expect(try await home.db.note(id: shared) != nil)
        #expect(try await home.db.note(id: secret) == nil)
        let text = try fileText(work)
        #expect(!text.contains("Surprise party") && !text.contains("Buy the cake"))
        #expect(!text.contains(secret.uuidString))
    }

    @Test("turning sync on later sends the list with everything in it")
    func turnOnLater() async throws {
        let world = SyncWorld(); defer { world.cleanUp() }
        let work = try world.mac("Work MacBook"), home = try world.mac("Home iMac")
        let list = try await work.newList("Groceries", synced: false)
        try await work.add("Oat milk", to: list)
        try await work.add("Coffee", to: list, level: 1)
        try await world.syncAll()
        #expect(try await home.db.note(id: list) == nil)

        try await work.setSynced(list, true)
        try await world.syncAll()
        let arrived = try #require(try await home.db.note(id: list))
        #expect(arrived.isSynced && !arrived.isOpen)
        #expect(try await home.texts(list) == ["Oat milk", "Coffee"])
        #expect(try await home.tasks(list).map(\.indentLevel) == [0, 1])
    }

    @Test("turning sync off on one Mac turns it off on both; each keeps its own copy")
    func turnOffEverywhere() async throws {
        let world = SyncWorld(); defer { world.cleanUp() }
        let work = try world.mac("Work MacBook"), home = try world.mac("Home iMac")
        let list = try await work.newList("Grading")
        let task = try await work.add("Year 2 batch", to: list)
        try await world.syncAll()

        try await home.setSynced(list, false)
        try await world.syncAll()
        #expect(try await work.db.note(id: list)?.isSynced == false)
        #expect(try await home.db.note(id: list) != nil)

        // From now on each copy is on its own, and the list's contents leave the folder.
        try await work.edit(task, "Year 2 batch (work)")
        try await home.add("Finals moderation", to: list)
        try await world.syncAll()
        #expect(try await work.texts(list) == ["Year 2 batch (work)"])
        #expect(try await home.texts(list) == ["Year 2 batch", "Finals moderation"])
        for mac in world.macs { #expect(!(try fileText(mac)).contains("Year 2 batch")) }
    }

    @Test("turning sync back on merges the two copies field by field; deletes made meanwhile still win")
    func turnBackOn() async throws {
        let world = SyncWorld(); defer { world.cleanUp() }
        let work = try world.mac("Work MacBook"), home = try world.mac("Home iMac")
        let list = try await work.newList("Trip")
        let train = try await work.add("Book train", to: list)
        let hotel = try await work.add("Book hotel", to: list)
        let visa = try await work.add("Visa", to: list)
        try await world.syncAll()
        try await work.setSynced(list, false)
        try await world.syncAll()

        world.clock.advance(minutes: 30)
        try await work.edit(train, "Book train (Friday)")
        try await home.toggle(hotel, in: list)
        try await home.delete(visa, in: list)
        try await home.rename(list, "Trip to Leeds")
        try await world.syncAll()

        world.clock.advance(minutes: 30)
        try await work.setSynced(list, true)
        try await world.syncAll()
        for mac in world.macs {
            #expect(try await mac.db.note(id: list)?.isSynced == true)
            #expect(try await mac.db.note(id: list)?.title == "Trip to Leeds")
            #expect(try await mac.texts(list) == ["Book train (Friday)", "Book hotel"])
            #expect(try await mac.tasks(list).last?.isDone == true)
        }
    }

    @Test("deleting a copy that doesn't sync leaves the other Mac's copy alone")
    func deleteUnsyncedCopy() async throws {
        let world = SyncWorld(); defer { world.cleanUp() }
        let work = try world.mac("Work MacBook"), home = try world.mac("Home iMac")
        let list = try await work.newList("Ideas")
        try await work.add("One", to: list)
        try await world.syncAll()
        try await home.setSynced(list, false)
        try await world.syncAll()

        try await home.deleteList(list)
        try await world.syncAll()
        #expect(try await home.db.note(id: list) == nil)
        #expect(try await work.texts(list) == ["One"])
    }

    @Test("switching sync off and deleting at once (before a sync) deletes only this Mac's copy")
    func offThenDeleteRightAway() async throws {
        let world = SyncWorld(); defer { world.cleanUp() }
        let work = try world.mac("Work MacBook"), home = try world.mac("Home iMac")
        let list = try await work.newList("Old project")
        try await work.add("Notes", to: list)
        try await world.syncAll()

        try await home.setSynced(list, false)    // no sync in between: the switch isn't recorded yet
        try await home.deleteList(list)
        try await world.syncAll()
        #expect(try await home.db.note(id: list) == nil)
        let kept = try #require(try await work.db.note(id: list))
        #expect(!kept.isSynced)
        #expect(try await work.texts(list) == ["Notes"])
    }

    @Test("each Mac's welcome notes stay on that Mac")
    func welcomeNotesStayPut() async throws {
        let world = SyncWorld(); defer { world.cleanUp() }
        let work = try world.mac("Work MacBook"), home = try world.mac("Home iMac")
        try work.db.seedSampleDataIfEmpty()
        try home.db.seedSampleDataIfEmpty()
        try await work.newList("This week")
        try await world.syncAll()
        #expect(try await home.db.allNotes().map(\.title).sorted()
                == ["Shortcuts ⌨️", "This week", "Welcome to Tic 👋"])
    }

    // MARK: - Images

    @Test("an image arrives on the other Mac with its crop, stored once in the folder")
    func imageTravels() async throws {
        let world = SyncWorld(); defer { world.cleanUp() }
        let work = try world.mac("Work MacBook"), home = try world.mac("Home iMac")
        let list = try await work.newList("Whiteboard")
        let task = try await work.add("Photo of the plan", to: list)
        let picture = Data("png bytes of the whiteboard".utf8)
        try await work.setImage(task, picture)
        try await work.crop(task, CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6))
        try await world.syncAll()

        #expect(try await home.imageData(task) == picture)
        #expect(try await home.imageCrop(task, in: list) == CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6))
        let hash = AppDatabase.imageHash(picture)
        #expect(FileManager.default.fileExists(atPath: home.folder.appendingPathComponent("images/\(hash).png").path))
        #expect(!(try fileText(work)).contains("whiteboard"))   // the bytes live in images/, not the list file
    }

    @Test("an image whose file arrives after its list shows up then, and isn't removed meanwhile")
    func imageArrivesLate() async throws {
        let world = SyncWorld(); defer { world.cleanUp() }
        let work = try world.mac("Work MacBook"), home = try world.mac("Home iMac")
        let list = try await work.newList("Receipts")
        let task = try await work.add("Taxi", to: list)
        let picture = Data("receipt".utf8)
        try await work.setImage(task, picture)
        await work.syncNow()

        try world.deliver(work, to: home, images: false)      // the list file first, the picture still uploading
        await home.syncNow()
        #expect(try await home.texts(list) == ["Taxi"])
        #expect(try await home.imageData(task) == nil)
        try world.deliver(home, to: work)
        await work.syncNow()
        #expect(try await work.imageData(task) == picture)     // home's file didn't read as "image removed"

        try world.deliver(work, to: home)
        await home.syncNow()
        #expect(try await home.imageData(task) == picture)
        #expect(try await world.converged())
    }

    @Test("a re-crop, a replacement and a removal each travel")
    func imageEditsTravel() async throws {
        let world = SyncWorld(); defer { world.cleanUp() }
        let work = try world.mac("Work MacBook"), home = try world.mac("Home iMac")
        let list = try await work.newList("Sketches")
        let task = try await work.add("Logo", to: list)
        try await work.setImage(task, Data("v1".utf8))
        try await world.syncAll()

        try await home.crop(task, CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        try await world.syncAll()
        #expect(try await work.imageCrop(task, in: list) == CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))

        try await work.setImage(task, Data("v2".utf8))
        try await world.syncAll()
        #expect(try await home.imageData(task) == Data("v2".utf8))

        try await home.removeImage(task)
        try await world.syncAll()
        #expect(try await work.imageData(task) == nil)
        #expect(try await work.texts(list) == ["Logo"])
    }

    @Test("pictures in a list that doesn't sync aren't written to the folder")
    func unsyncedImagesStayHome() async throws {
        let world = SyncWorld(); defer { world.cleanUp() }
        let work = try world.mac("Work MacBook"), home = try world.mac("Home iMac")
        let list = try await work.newList("Private", synced: false)
        let task = try await work.add("ID scan", to: list)
        try await work.setImage(task, Data("passport".utf8))
        try await world.syncAll()
        let images = try FileManager.default.contentsOfDirectory(atPath: work.folder.appendingPathComponent("images").path)
        #expect(images.isEmpty)
        #expect(try await home.db.note(id: list) == nil)
    }

    @Test("unused picture files are cleared out once they're a week old; used and recent ones stay")
    func clearsUnusedImages() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tic-images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        for (name, date) in [("used", old), ("unused-old", old), ("unused-new", Date())] {
            let url = dir.appendingPathComponent("\(name).png")
            try Data(name.utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        FolderSync.removeUnusedImages(in: dir, keeping: ["used"])
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(left == ["unused-new.png", "used.png"])
    }
}
