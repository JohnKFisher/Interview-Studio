import AppKit
import Core
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var welcomeWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installMenus()
        showWelcomeIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        showWelcomeIfNeeded()
        return false
    }

    @objc func newProject(_ sender: Any?) {
        let document = InterviewStudioDocument()
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
        closeWelcome()
    }

    @objc func openProject(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowedContentTypes = [UTType(filenameExtension: "interviewstudio") ?? .package]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openDocument(at: url)
    }

    @objc func importLegacyProject(_ sender: Any?) {
        let sourcePanel = NSOpenPanel()
        sourcePanel.canChooseDirectories = true
        sourcePanel.canChooseFiles = false
        sourcePanel.message = "Choose the legacy project folder containing final_manifest.json."
        guard sourcePanel.runModal() == .OK, let sourceURL = sourcePanel.url else { return }
        do {
            let analysis = try LegacyMigrationService().analyze(sourceFolder: sourceURL)
            if !analysis.canImport {
                showAlert(title: "Legacy project needs review", message: analysis.findings.filter { $0.severity == .blocker }.map(\.message).joined(separator: "\n"))
                return
            }
            let savePanel = NSSavePanel()
            savePanel.nameFieldStringValue = "\(InterviewStudioKey.safeFilenameComponent(analysis.personName, fallback: "Person")) Interview.interviewstudio"
            savePanel.canCreateDirectories = true
            savePanel.allowedContentTypes = [UTType(filenameExtension: "interviewstudio") ?? .package]
            guard savePanel.runModal() == .OK, let destinationURL = savePanel.url else { return }
            let result = try LegacyMigrationService().import(analysis: analysis, to: destinationURL)
            openDocument(at: result.packageURL)
        } catch {
            showAlert(title: "Legacy import failed", message: error.localizedDescription)
        }
    }

    @objc func saveDocument(_ sender: Any?) {
        NSDocumentController.shared.currentDocument?.save(nil)
    }

    @objc func verifyPackage(_ sender: Any?) {
        guard let document = NSDocumentController.shared.currentDocument as? InterviewStudioDocument, let store = document.packageStore else {
            showAlert(title: "No saved package", message: "Save the document before verifying its package inventory.")
            return
        }
        do {
            try store.verifyInventory()
            showAlert(title: "Package verified", message: "The package inventory and recorded source bytes are intact.")
        } catch {
            showAlert(title: "Package verification failed", message: error.localizedDescription)
        }
    }

    private func showWelcomeIfNeeded() {
        guard NSDocumentController.shared.documents.isEmpty else { return }
        if welcomeWindowController == nil {
            let view = WelcomeView(
                onNew: { [weak self] in self?.newProject(nil) },
                onOpen: { [weak self] in self?.openProject(nil) },
                onImport: { [weak self] in self?.importLegacyProject(nil) }
            )
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Yearly Interview Studio"
            window.contentView = NSHostingView(rootView: view)
            window.center()
            welcomeWindowController = NSWindowController(window: window)
        }
        welcomeWindowController?.showWindow(nil)
    }

    private func closeWelcome() {
        welcomeWindowController?.close()
        welcomeWindowController = nil
    }

    private func openDocument(at url: URL) {
        do {
            let document = InterviewStudioDocument()
            try document.read(from: url, ofType: "com.jkfisher.yearly-interview-studio.project")
            NSDocumentController.shared.addDocument(document)
            document.makeWindowControllers()
            document.showWindows()
            closeWelcome()
        } catch {
            showAlert(title: "Open failed", message: error.localizedDescription)
        }
    }

    private func installMenus() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Yearly Interview Studio", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Yearly Interview Studio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Project", action: #selector(newProject(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Open Project…", action: #selector(openProject(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Import Legacy Project…", action: #selector(importLegacyProject(_:)), keyEquivalent: "i")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Save", action: #selector(saveDocument(_:)), keyEquivalent: "s")
        fileMenu.addItem(withTitle: "Verify Package", action: #selector(verifyPackage(_:)), keyEquivalent: "v")
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: #selector(undo(_:)), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: #selector(redo(_:)), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.mainMenu = mainMenu
    }

    @objc private func undo(_ sender: Any?) { NSDocumentController.shared.currentDocument?.undoManager?.undo() }
    @objc private func redo(_ sender: Any?) { NSDocumentController.shared.currentDocument?.undoManager?.redo() }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

@main
struct YearlyInterviewStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

private struct WelcomeView: View {
    let onNew: () -> Void
    let onOpen: () -> Void
    let onImport: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "film.stack")
                .font(.system(size: 54))
                .foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text("Yearly Interview Studio")
                    .font(.largeTitle.weight(.semibold))
                Text("Create a durable interview project, refine answers, and hand validated inputs to the protected Assembly renderer.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 520)
            }
            HStack(spacing: 12) {
                Button("New Project", action: onNew)
                    .buttonStyle(.borderedProminent)
                Button("Open Project…", action: onOpen)
                    .buttonStyle(.bordered)
                Button("Import Legacy Project…", action: onImport)
                    .buttonStyle(.bordered)
            }
            Text("Source recordings remain inside the project package; generated media is derived and rebuildable.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(48)
    }
}
