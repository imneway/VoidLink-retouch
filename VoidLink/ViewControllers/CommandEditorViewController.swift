//
//  CommandEditorViewController.swift
//  VoidLink
//
//  Add / edit one command-manager entry (command string, alias, quick-menu
//  pin, icon), the SF Symbol picker behind its icon row, and the shared
//  quick-menu icon renderer.
//

import UIKit

private func L(_ key: String, _ args: CVarArg...) -> String {
    let format = NSLocalizedString(key, tableName: "Localizable", bundle: .main, value: "", comment: "")
    return args.isEmpty ? format : String(format: format, arguments: args)
}

// MARK: - Icon rendering

// Every quick-menu item is a disc. A "*.circle" / "*.circle.fill" symbol is
// the disc itself; any other symbol, or the alias initials when no symbol is
// set, is knocked out of a filled disc so all items read the same. Returns a
// template image: the caller picks the tint.
@objc public class QuickMenuIcon: NSObject {

    @objc public static func image(for command: RemoteCommand, diameter: CGFloat) -> UIImage {
        return image(symbolName: command.iconName, alias: command.alias, diameter: diameter)
    }

    @objc public static func image(symbolName: String?, alias: String, diameter d: CGFloat) -> UIImage {
        let rect = CGRect(x: 0, y: 0, width: d, height: d)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: rect.size, format: format).image { ctx in
            if let name = symbolName, isDiscSymbol(name),
               let symbol = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: d)) {
                draw(symbol, fittingIn: rect, blendMode: .normal)
                return
            }
            UIColor.black.setFill()
            UIBezierPath(ovalIn: rect).fill()
            ctx.cgContext.setBlendMode(.destinationOut)
            if let name = symbolName,
               let symbol = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: d * 0.5, weight: .semibold)) {
                draw(symbol, fittingIn: rect.insetBy(dx: d * 0.24, dy: d * 0.24), blendMode: .destinationOut)
            } else {
                let text = initials(of: alias) as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: d * (text.length > 1 ? 0.36 : 0.44), weight: .bold),
                    .foregroundColor: UIColor.black,
                ]
                let size = text.size(withAttributes: attrs)
                text.draw(at: CGPoint(x: (d - size.width) / 2, y: (d - size.height) / 2), withAttributes: attrs)
            }
        }
        return image.withRenderingMode(.alwaysTemplate)
    }

    static func isDiscSymbol(_ name: String) -> Bool {
        return name == "circle" || name == "circle.fill" || name.hasSuffix(".circle") || name.hasSuffix(".circle.fill")
    }

    static func isValidSymbol(_ name: String) -> Bool {
        return UIImage(systemName: name) != nil
    }

    private static func draw(_ symbol: UIImage, fittingIn box: CGRect, blendMode: CGBlendMode) {
        let s = symbol.size
        guard s.width > 0, s.height > 0 else { return }
        let scale = min(box.width / s.width, box.height / s.height)
        let w = s.width * scale, h = s.height * scale
        let target = CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
        symbol.withTintColor(.black, renderingMode: .alwaysOriginal).draw(in: target, blendMode: blendMode, alpha: 1)
    }

    // "Xbox Game Bar" -> "XG", "Eden" -> "Ed", "复制(Copy)" -> "复".
    static func initials(of alias: String) -> String {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        guard first.isASCII, first.isLetter || first.isNumber else { return String(first) }
        let words = trimmed.split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) })
        if words.count >= 2, let a = words[0].first, let b = words[1].first {
            return (String(a) + String(b)).uppercased()
        }
        let word = words.first ?? Substring(trimmed)
        return String(word.prefix(1)).uppercased() + String(word.dropFirst().prefix(1)).lowercased()
    }
}

// MARK: - Symbol catalog

// Hand-picked; names the running iOS does not know are filtered out, and the
// picker's search also accepts any exact SF Symbol name.
private enum SymbolCatalog {
    static let sections: [(String, [String])] = [
        ("Numbers & Letters",
         (0...9).map { "\($0).circle.fill" } + "abcdefghijklmnopqrstuvwxyz".map { "\($0).circle.fill" }),
        ("Games", [
            "gamecontroller.fill", "gamecontroller", "logo.playstation", "logo.xbox", "arcade.stick.console.fill",
            "dpad.fill", "l.joystick.fill", "r.joystick.fill", "circle.grid.cross.fill", "trophy.fill", "crown.fill",
            "flag.checkered", "target", "scope", "puzzlepiece.fill", "dice.fill", "suit.club.fill", "suit.heart.fill",
        ]),
        ("Display & Windows", [
            "display", "display.2", "rectangle.on.rectangle", "rectangle.on.rectangle.circle.fill",
            "rectangle.split.2x1", "rectangle.split.3x1", "rectangle.inset.filled", "macwindow",
            "macwindow.on.rectangle", "uiwindow.split.2x1", "sidebar.left", "square.grid.2x2.fill",
            "rectangle.3.group.fill", "pip.enter", "pip.exit", "aspectratio", "arrow.up.left.and.arrow.down.right",
            "arrow.down.right.and.arrow.up.left", "tv", "desktopcomputer", "pc", "laptopcomputer",
        ]),
        ("Media", [
            "play.fill", "pause.fill", "playpause.fill", "stop.fill", "forward.fill", "backward.fill",
            "forward.end.fill", "backward.end.fill", "speaker.wave.2.fill", "speaker.slash.fill",
            "speaker.plus.fill", "speaker.minus.fill", "mic.fill", "mic.slash.fill", "music.note",
            "camera.fill", "video.fill", "record.circle", "photo.fill", "film",
        ]),
        ("System", [
            "power", "restart", "moon.fill", "sun.max.fill", "lock.fill", "lock.open.fill", "gearshape.fill",
            "slider.horizontal.3", "wrench.and.screwdriver.fill", "terminal.fill", "command", "option", "control",
            "shift.fill", "escape", "delete.left.fill", "return", "keyboard", "magnifyingglass", "bell.fill",
            "wifi", "cpu", "memorychip", "externaldrive.fill", "folder.fill", "doc.fill", "trash.fill",
            "doc.on.doc.fill", "doc.on.clipboard", "scissors", "pencil", "cursorarrow", "cursorarrow.click",
            "hand.tap.fill", "house.fill", "globe", "network", "link", "square.and.arrow.up",
            "xmark.circle.fill", "checkmark.circle.fill", "questionmark.circle.fill", "info.circle.fill",
            "exclamationmark.triangle.fill", "ellipsis.circle.fill",
        ]),
        ("Arrows", [
            "arrow.up", "arrow.down", "arrow.left", "arrow.right", "arrow.clockwise", "arrow.counterclockwise",
            "arrow.uturn.backward", "arrow.triangle.2.circlepath", "arrow.left.arrow.right",
            "arrow.left.arrow.right.circle.fill", "arrow.up.arrow.down", "arrow.up.and.down.and.arrow.left.and.right",
            "chevron.up", "chevron.down", "chevron.left", "chevron.right", "repeat", "shuffle",
        ]),
        ("Symbols", [
            "star.fill", "heart.fill", "bolt.fill", "flame.fill", "leaf.fill", "bookmark.fill", "tag.fill",
            "flag.fill", "pin.fill", "sparkles", "wand.and.stars", "eye.fill", "eye.slash.fill", "person.fill",
            "person.2.fill", "bubble.left.fill", "envelope.fill", "phone.fill", "cart.fill", "gift.fill",
            "cup.and.saucer.fill", "car.fill", "airplane",
        ]),
    ]

    static let available: [(String, [String])] = sections.map { ($0.0, $0.1.filter(QuickMenuIcon.isValidSymbol)) }
}

// MARK: - Symbol picker

private final class SymbolCell: UICollectionViewCell {
    static let reuseID = "SymbolCell"
    let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.tintColor = UIColor(white: 1, alpha: 0.6)
        imageView.contentMode = .scaleAspectFit
        contentView.addSubview(imageView)
        contentView.layer.cornerRadius = 12
        contentView.layer.borderColor = UIColor.systemBlue.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = contentView.bounds.insetBy(dx: 6, dy: 6)
    }

    func configure(image: UIImage, chosen: Bool) {
        imageView.image = image
        contentView.layer.borderWidth = chosen ? 2 : 0
        contentView.backgroundColor = chosen ? UIColor(white: 1, alpha: 0.12) : .clear
    }
}

private final class SymbolHeader: UICollectionReusableView {
    static let reuseID = "SymbolHeader"
    let label = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.inset(by: UIEdgeInsets(top: 8, left: 4, bottom: 0, right: 4))
    }
}

final class SymbolPickerViewController: UICollectionViewController, UISearchResultsUpdating {

    var onPick: ((String?) -> Void)?
    private let current: String?
    private let alias: String
    // nil entry = "no icon, draw the alias initials".
    private var sections: [(String, [String?])] = []

    init(current: String?, alias: String) {
        self.current = current
        self.alias = alias
        let layout = UICollectionViewFlowLayout()
        layout.itemSize = CGSize(width: 56, height: 56)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = UIEdgeInsets(top: 4, left: 16, bottom: 12, right: 16)
        layout.headerReferenceSize = CGSize(width: 0, height: 30)
        super.init(collectionViewLayout: layout)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("Choose Icon")
        collectionView.backgroundColor = .systemGroupedBackground
        collectionView.register(SymbolCell.self, forCellWithReuseIdentifier: SymbolCell.reuseID)
        collectionView.register(SymbolHeader.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                                withReuseIdentifier: SymbolHeader.reuseID)
        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = L("Search SF Symbols or type a name")
        search.searchBar.autocapitalizationType = .none
        search.searchBar.autocorrectionType = .no
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        rebuild(query: "")
    }

    private func rebuild(query raw: String) {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty {
            sections = [(L("None"), [nil])] + SymbolCatalog.available.map { (L($0.0), $0.1.map { Optional($0) }) }
        } else {
            var seen = Set<String>()
            var hits: [String] = []
            for (_, names) in SymbolCatalog.available {
                for name in names where name.contains(query) && seen.insert(name).inserted { hits.append(name) }
            }
            if !seen.contains(query) && QuickMenuIcon.isValidSymbol(query) { hits.insert(query, at: 0) }
            sections = [(L("Search Results"), hits.map { Optional($0) })]
        }
        collectionView.reloadData()
    }

    func updateSearchResults(for searchController: UISearchController) {
        rebuild(query: searchController.searchBar.text ?? "")
    }

    override func numberOfSections(in collectionView: UICollectionView) -> Int { sections.count }

    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].1.count
    }

    override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: SymbolCell.reuseID, for: indexPath) as! SymbolCell
        let name = sections[indexPath.section].1[indexPath.item]
        cell.configure(image: QuickMenuIcon.image(symbolName: name, alias: alias, diameter: 44), chosen: name == current)
        return cell
    }

    override func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String,
                                 at indexPath: IndexPath) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: SymbolHeader.reuseID,
                                                                     for: indexPath) as! SymbolHeader
        header.label.text = sections[indexPath.section].0
        return header
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        onPick?(sections[indexPath.section].1[indexPath.item])
        navigationItem.searchController?.isActive = false
        navigationController?.popViewController(animated: true)
    }
}

// MARK: - Command editor

private final class TextFieldCell: UITableViewCell {
    let field = UITextField()
    init(placeholder: String, text: String?) {
        super.init(style: .default, reuseIdentifier: nil)
        selectionStyle = .none
        field.placeholder = placeholder
        field.text = text
        field.clearButtonMode = .whileEditing
        field.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            field.topAnchor.constraint(equalTo: contentView.topAnchor),
            field.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

// Edits commands[editIndex] in place, or adds a new command when editIndex is
// nil (prefilled for "duplicate"). onFinish gets the row index of the saved
// command in CommandManager's list.
final class CommandEditorViewController: UITableViewController {

    var onFinish: ((Int) -> Void)?
    private let editIndex: Int?
    private var iconName: String?
    private var wasPinned = false

    private let commandCell: TextFieldCell
    private let aliasCell: TextFieldCell
    private let pinCell = UITableViewCell(style: .default, reuseIdentifier: nil)
    private let pinSwitch = UISwitch()
    private let iconCell = UITableViewCell(style: .value1, reuseIdentifier: nil)

    init(editIndex: Int?, prefillCommand: String? = nil) {
        self.editIndex = editIndex
        let existing = editIndex.flatMap { i -> RemoteCommand? in
            let all = CommandManager.shared.getAllCommands()
            return i >= 0 && i < all.count ? all[i] : nil
        }
        commandCell = TextFieldCell(placeholder: L("Command"), text: existing?.cmdString ?? prefillCommand)
        aliasCell = TextFieldCell(placeholder: L("Alias (optional)"), text: existing?.alias)
        iconName = existing?.iconName
        wasPinned = existing?.pinned ?? false
        super.init(style: .insetGrouped)
        pinSwitch.isOn = wasPinned
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L(editIndex == nil ? "New Command" : "Edit Command")
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(saveTapped))

        for field in [commandCell.field, aliasCell.field] {
            field.autocorrectionType = .no
            field.spellCheckingType = .no
        }
        commandCell.field.keyboardType = .asciiCapable
        commandCell.field.autocapitalizationType = .allCharacters
        aliasCell.field.addTarget(self, action: #selector(aliasChanged), for: .editingChanged)

        pinCell.textLabel?.text = L("Pin to Quick Menu")
        pinCell.selectionStyle = .none
        pinCell.accessoryView = pinSwitch
        pinSwitch.addTarget(self, action: #selector(pinToggled), for: .valueChanged)

        iconCell.textLabel?.text = L("Icon")
        iconCell.accessoryType = .disclosureIndicator
        refreshIconCell()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if editIndex == nil && (commandCell.field.text ?? "").isEmpty { commandCell.field.becomeFirstResponder() }
    }

    private var currentAlias: String {
        let alias = (aliasCell.field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return alias.isEmpty ? (commandCell.field.text ?? "") : alias
    }

    private func refreshIconCell() {
        iconCell.imageView?.image = QuickMenuIcon.image(symbolName: iconName, alias: currentAlias, diameter: 30)
        iconCell.imageView?.tintColor = .label
        iconCell.detailTextLabel?.text = iconName ?? L("None")
    }

    @objc private func aliasChanged() {
        if iconName == nil { refreshIconCell() } // initials follow the alias
    }

    @objc private func pinToggled() {
        guard pinSwitch.isOn else { return }
        let others = CommandManager.shared.pinnedCount() - (wasPinned ? 1 : 0)
        if others >= CommandManager.maxPinnedCommands {
            pinSwitch.setOn(false, animated: true)
            showMessage(L("Quick menu is full"), L("Up to %d commands can be pinned. Unpin one first.", CommandManager.maxPinnedCommands))
        }
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func saveTapped() {
        let cmd = (commandCell.field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard CommandManager.shared.extractKeyStringsFromComboCommand(from: cmd) != nil else {
            showMessage(L("Invalid command"), L("Use key names joined with +, e.g. CTRL+SHIFT+ESC"))
            return
        }
        let alias = aliasCell.field.text ?? ""
        let row: Int
        if let index = editIndex {
            guard CommandManager.shared.updateCommand(at: index, cmdString: cmd, alias: alias,
                                                      pinned: pinSwitch.isOn, iconName: iconName) else { return }
            row = index
        } else {
            let command = RemoteCommand(cmdString: cmd, alias: alias, pinned: pinSwitch.isOn, iconName: iconName)
            guard CommandManager.shared.addCommand(command) else { return }
            row = CommandManager.shared.getAllCommands().count - 1
        }
        let finish = onFinish
        dismiss(animated: true) { finish?(row) }
    }

    private func showMessage(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("OK"), style: .default))
        present(alert, animated: true)
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 2 }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch (indexPath.section, indexPath.row) {
        case (0, 0): return commandCell
        case (0, 1): return aliasCell
        case (1, 0): return pinCell
        default: return iconCell
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return section == 1
            ? L("Pinned commands appear in the bottom-right quick menu in list order, up to %d.", CommandManager.maxPinnedCommands)
            : nil
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath == IndexPath(row: 1, section: 1) else { return }
        view.endEditing(true)
        let picker = SymbolPickerViewController(current: iconName, alias: currentAlias)
        picker.onPick = { [weak self] name in
            self?.iconName = name
            self?.refreshIconCell()
        }
        navigationController?.pushViewController(picker, animated: true)
    }
}
