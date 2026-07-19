import AppKit

enum MenuBarIcon {
    static let image: NSImage? = {
        let resourceName = "AudioMonsterMenuBarTemplate"
        let image =
            NSImage(named: NSImage.Name(resourceName))
            ?? {
                guard let url = Bundle.main.url(forResource: resourceName, withExtension: "png") else {
                    return nil
                }
                return NSImage(contentsOf: url)
            }()
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        return image
    }()
}
