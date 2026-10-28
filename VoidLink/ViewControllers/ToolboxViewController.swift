//
//  KeyManagerViewController.swift
//  VoidLink
//
//  Created by True砖家 on 2024/7/23.
//  Copyright © 2024 True砖家 on Bilibili. All rights reserved.
//

import UIKit

@objc protocol ToolboxSpecialEntryDelegate: NSObjectProtocol {
    @objc optional func openWidgetLayoutTool()
    @objc optional func bringUpSoftKeyboard()
    @objc optional func enterPip()
    @objc optional func toggleStatsOverlay()
    @objc optional func disconnectAndQuitApp()
    @objc optional func toggleSoftKeyboard()
    @objc optional func cycleAudioOutput()
    @objc optional func audioOutputStatus() -> String?
}


@objc public class ToolboxViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    
    @objc weak var specialEntryDelegate: ToolboxSpecialEntryDelegate?
    private static let emptyIconSlot: UIImage = {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 28, height: 28), format: format).image { _ in }
    }()
    public let tableView = UITableView()
    private let addButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private let editButton = UIButton(type: .system)
    private let exitButton = UIButton(type: .system)
    private let viewBackgroundColor = UIColor(white: 0.2, alpha: 0.8);
    private let titleLabel = UILabel()
    @objc public var specialEntries : NSMutableArray = ["widgetLayoutTool", "bringUpSoftKeyboard", "enterPip", "toggleStatsOverlay", "disconnectAndQuitApp"]
    private let specialEntryAliasDic : [String:String] = [
        "widgetLayoutTool":SwiftLocalizationHelper.localizedString(forKey: "[ On-screen widget tool ]"),
        "bringUpSoftKeyboard":SwiftLocalizationHelper.localizedString(forKey: "[ Bring up soft keyboard ]"),
        "enterPip":SwiftLocalizationHelper.localizedString(forKey: "[ Enter picture-in-picture mode ]"),
        "toggleStatsOverlay":SwiftLocalizationHelper.localizedString(forKey: "[ Toggle stats overlay & graphs ]"),
        "disconnectAndQuitApp":SwiftLocalizationHelper.localizedString(forKey: "[ Disconnect & quit app ]")
    ]
    // Only show whitelisted special entries without deleting others, so they can be restored later
    private let allowedSpecialEntries: Set<String> = ["toggleStatsOverlay"]
    
    private var isEditingMode: Bool = false {
        didSet {
            updateEditingMode()
        }
    }
    
    override public func viewDidLoad() {
        super.viewDidLoad()
        
        setupViews()
        updateEditingMode()
        enforceSpecialEntriesVisibility()
        
        tableView.dataSource = self
        tableView.delegate = self
        
        // Register the cell class
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        //pass self to the CommandManager
        CommandManager.shared.viewController = self
    }
    
    
    override public func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        //setupConstraints()
        reloadTableView()
    }
    
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        enforceSpecialEntriesVisibility()

        //setupConstraints()
    }

    
    private func setupViews() {
        
        // Set corner radius
        view.layer.cornerRadius = 20  // Adjust the corner radius
        view.layer.masksToBounds = true
        
        // Set up the title label
        titleLabel.text = SwiftLocalizationHelper.localizedString(forKey: "Toolbox")
        titleLabel.font = UIFont.boldSystemFont(ofSize: 20)  // Adjust font size as needed
        titleLabel.textColor = UIColor.white  // Adjust color as needed
        titleLabel.textAlignment = .center
        view.addSubview(titleLabel)
        
        view.backgroundColor = viewBackgroundColor
        tableView.backgroundColor = .clear
        tableView.allowsSelectionDuringEditing = true
        tableView.tintColor = .white
        tableView.rowHeight = isIPhone() ? 47 : 60
        tableView.separatorColor = .white.withAlphaComponent(0.33)
        tableView.separatorInset = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        // Configure buttons
        addButton.setTitle(SwiftLocalizationHelper.localizedString(forKey: "Add / Duplicate"), for: .normal)
        deleteButton.setTitle(SwiftLocalizationHelper.localizedString(forKey: "Delete"), for: .normal)
        editButton.setTitle(SwiftLocalizationHelper.localizedString(forKey: "Edit"), for: .normal)
        exitButton.setTitle(SwiftLocalizationHelper.localizedString(forKey: "Exit"), for: .normal)
        addButton.titleLabel?.font = UIFont.systemFont(ofSize: 20) // Adjust the size as needed
        deleteButton.titleLabel?.font = UIFont.systemFont(ofSize: 20)
        editButton.titleLabel?.font = UIFont.systemFont(ofSize: 20)
        exitButton.titleLabel?.font = UIFont.systemFont(ofSize: 20)

        // Add subviews
        view.addSubview(tableView)
        view.addSubview(addButton)
        view.addSubview(deleteButton)
        view.addSubview(editButton)
        view.addSubview(exitButton)
        
        // Setup button targets
        addButton.addTarget(self, action: #selector(addButtonTapped), for: .touchUpInside)
        deleteButton.addTarget(self, action: #selector(deleteButtonTapped), for: .touchUpInside)
        editButton.addTarget(self, action: #selector(editButtonTapped), for: .touchUpInside)
        exitButton.addTarget(self, action: #selector(exitButtonTapped), for: .touchUpInside)

    }
    
    public override func updateViewConstraints() {
        self.setupConstraints()
        super.updateViewConstraints()
    }

    private func isIPhone()->Bool {
        return UIDevice.current.userInterfaceIdiom == .phone
    }
    
    @objc public func setupConstraints() {
        
        guard view.superview != nil else {
            return
        }
                
        NSLayoutConstraint.deactivate(view.constraints)

        view.translatesAutoresizingMaskIntoConstraints = false
        
        tableView.translatesAutoresizingMaskIntoConstraints = false
        addButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        editButton.translatesAutoresizingMaskIntoConstraints = false
        exitButton.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            
            // Set the width and height of the view
            view.widthAnchor.constraint(equalTo: view.superview!.widthAnchor, multiplier: isIPhone() ? 0.6 : 0.52),
            view.heightAnchor.constraint(equalTo: view.superview!.heightAnchor, multiplier: 0.8),
            // Set the width and height of the view
            //view.leadingAnchor.constraint(equalTo: view.superview!.leadingAnchor, constant: 60),
            //view.trailingAnchor.constraint(equalTo: view.superview!.trailingAnchor, constant: -60),

            // Center the view horizontally and vertically
            view.centerXAnchor.constraint(equalTo: view.superview!.centerXAnchor),
            view.centerYAnchor.constraint(equalTo: view.superview!.centerYAnchor),
            
            // ViewTitle constrains
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 13.5),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            
            
            // TableView constraints
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            tableView.topAnchor.constraint(equalTo: view.topAnchor, constant: 50),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -60),
            
            // ExitButton constraints
            exitButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 25),
            exitButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            
            // EditButton constraints
            editButton.leadingAnchor.constraint(equalTo: exitButton.trailingAnchor, constant: 25),
            editButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            
            // AddButton constraints
            addButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -25),
            addButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            
            // DeleteButton constraints
            deleteButton.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -25),
            deleteButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
        ])
    }


    private func updateEditingMode() {
        addButton.isEnabled = isEditingMode
        deleteButton.isEnabled = isEditingMode
        if(isEditingMode){ editButton.setTitle(SwiftLocalizationHelper.localizedString(forKey: "Done"), for: .normal) }
        else{ editButton.setTitle(SwiftLocalizationHelper.localizedString(forKey: "Edit"), for: .normal) }
        tableView.setEditing(isEditingMode, animated: true)
    }
    
    @objc private func addButtonTapped() {
        // Duplicate: prefill the selected command's string (alias left empty).
        var prefill: String? = nil
        if let selectedIndexPath = self.tableView.indexPathForSelectedRow {
            if isSpecialEntrySelected() {return}
            let source = CommandManager.shared.getAllCommands()[selectedIndexPath.row-specialEntries.count]
            if !CommandManager.shared.isBuiltIn(source) { prefill = source.cmdString }
        }
        presentCommandEditor(editIndex: nil, prefill: prefill)
    }

    private func presentCommandEditor(editIndex: Int?, prefill: String? = nil) {
        let editor = CommandEditorViewController(editIndex: editIndex, prefillCommand: prefill)
        editor.onFinish = { [weak self] commandIndex in
            guard let self = self else { return }
            self.reloadTableView()
            let row = commandIndex + self.specialEntries.count
            if row < self.tableView.numberOfRows(inSection: 0) {
                self.tableView.selectRow(at: IndexPath(row: row, section: 0), animated: true, scrollPosition: .middle)
            }
        }
        let nav = UINavigationController(rootViewController: editor)
        nav.modalPresentationStyle = .formSheet
        nav.overrideUserInterfaceStyle = .dark
        present(nav, animated: true)
    }

    private func commandIndex(for indexPath: IndexPath) -> Int? {
        let index = indexPath.row - specialEntries.count
        return index >= 0 && index < CommandManager.shared.getAllCommands().count ? index : nil
    }

    private func togglePinned(commandIndex index: Int) {
        let command = CommandManager.shared.getAllCommands()[index]
        if !command.pinned && CommandManager.shared.pinnedCount() >= CommandManager.maxPinnedCommands {
            let alert = UIAlertController(title: SwiftLocalizationHelper.localizedString(forKey: "Quick menu is full"),
                                          message: SwiftLocalizationHelper.localizedString(forKey: "Up to %d commands can be pinned. Unpin one first.", CommandManager.maxPinnedCommands),
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: SwiftLocalizationHelper.localizedString(forKey: "OK"), style: .default))
            present(alert, animated: true)
            return
        }
        _ = CommandManager.shared.updateCommand(at: index, cmdString: command.cmdString, alias: command.alias,
                                                pinned: !command.pinned, iconName: command.iconName)
    }
    
    
    @objc private func deleteButtonTapped() {
        guard let selectedIndexPath = tableView.indexPathForSelectedRow else {
            return
        }
        
        if isSpecialEntrySelected() {return}
        if let index = commandIndex(for: selectedIndexPath),
           CommandManager.shared.isBuiltIn(CommandManager.shared.getAllCommands()[index]) { return } // built-ins can't be deleted
        
        let previouslySelectedIndexPath = selectedIndexPath // memorize selected row before reloading tableview
        
        CommandManager.shared.deleteCommand(at: selectedIndexPath.row-specialEntries.count)
        reloadTableView()
        // target new entry after deletion
        var targetRowAfterDel = previouslySelectedIndexPath.row - 1
        if targetRowAfterDel < 0 { targetRowAfterDel = 0 }
        let targetIndexPathAfterDel = IndexPath(row: targetRowAfterDel, section: previouslySelectedIndexPath.section)
            if targetRowAfterDel < tableView.numberOfRows(inSection: previouslySelectedIndexPath.section) {
                tableView.selectRow(at: targetIndexPathAfterDel, animated: true, scrollPosition: .middle) // shift highlight to the target entry after deletion
            }
    }
    
    @objc private func editButtonTapped() {
        isEditingMode.toggle()
        deleteButton.isEnabled = !isSpecialEntrySelected()
        addButton.isEnabled = !isSpecialEntrySelected()
    }
    
    @objc private func exitButtonTapped() {
        dismiss(animated: true, completion: nil)
    }
    
    @objc public func reloadTableView() {
        enforceSpecialEntriesVisibility()
        tableView.layoutIfNeeded()
        tableView.reloadData()
        
        /*
        let previouslySelectedIndexPath = tableView.indexPathForSelectedRow
        if let indexPath = previouslySelectedIndexPath {
            // Make sure the indexPath is still valid and scroll to the selected indexPath
            if indexPath.row < tableView.numberOfRows(inSection: indexPath.section) {
                tableView.selectRow(at: indexPath, animated: true, scrollPosition: .middle) // keep the entry of previous index selected.
            }
        } */
    }

    private func enforceSpecialEntriesVisibility() {
        // Filter to only keep allowed special entries, do not delete underlying definitions
        let filtered = NSMutableArray()
        for item in specialEntries {
            if let key = item as? String, allowedSpecialEntries.contains(key) {
                filtered.add(key)
            }
        }
        if !filtered.isEqual(to: specialEntries as! [Any]) {
            specialEntries = filtered
        }
    }
    
    // UITableViewDataSource
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return specialEntries.count + CommandManager.shared.getAllCommands().count
    }
    
    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        // Configure cell appearance
        cell.backgroundColor = .clear // Set background color of the cell
        cell.textLabel?.textColor = UIColor.white // Set font color of the text
        cell.textLabel?.font = UIFont.systemFont(ofSize: 18.5)
        
        
        cell.tintColor = .white
        // Set custom selection highlight color (12% white)
        let selectedBackgroundView = UIView()
        selectedBackgroundView.backgroundColor = UIColor(white: 1.0, alpha: 0.12)
        cell.selectedBackgroundView = selectedBackgroundView
        
        if indexPath.row < specialEntries.count {
            cell.textLabel?.text = specialEntryAliasDic[specialEntries[indexPath.row] as! String]
            cell.imageView?.image = nil
            cell.accessoryView = nil
            cell.editingAccessoryType = .none
        }
        else {
            let command = CommandManager.shared.getAllCommands()[indexPath.row-specialEntries.count]
            cell.textLabel?.text = command.alias
            if command.cmdString.uppercased() == CommandManager.audioOutputCommand,
               let status = specialEntryDelegate?.audioOutputStatus?() {
                // Current audio output, dimmed after the name.
                let text = NSMutableAttributedString(string: command.alias, attributes: [.foregroundColor: UIColor.white])
                text.append(NSAttributedString(string: "   " + status, attributes: [
                    .foregroundColor: UIColor(white: 1, alpha: 0.5),
                    .font: UIFont.systemFont(ofSize: 15),
                ]))
                cell.textLabel?.attributedText = text
            }
            // Only pinned commands show their quick-menu icon; the rest keep an
            // empty slot of the same size so every alias stays aligned.
            cell.imageView?.image = command.pinned
                ? QuickMenuIcon.image(for: command, diameter: 28)
                : ToolboxViewController.emptyIconSlot
            cell.imageView?.tintColor = UIColor(white: 1, alpha: 0.6)
            if command.pinned {
                let pin = UIImageView(image: UIImage(systemName: "pin.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14)))
                pin.tintColor = UIColor(white: 1, alpha: 0.45)
                cell.accessoryView = pin
            } else {
                cell.accessoryView = nil
            }
            cell.editingAccessoryType = .detailButton // edit mode: (i) opens the editor
        }
        return cell
    }

    // Normal mode: swipe left on a command to edit it or (un)pin it to the
    // quick menu.
    public func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let index = commandIndex(for: indexPath) else { return nil }
        let pinned = CommandManager.shared.getAllCommands()[index].pinned
        let edit = UIContextualAction(style: .normal, title: SwiftLocalizationHelper.localizedString(forKey: "Edit")) { [weak self] _, _, done in
            self?.presentCommandEditor(editIndex: index)
            done(true)
        }
        edit.backgroundColor = .systemBlue
        let pin = UIContextualAction(style: .normal, title: SwiftLocalizationHelper.localizedString(forKey: pinned ? "Unpin" : "Pin")) { [weak self] _, _, done in
            self?.togglePinned(commandIndex: index)
            done(true)
        }
        pin.backgroundColor = .systemOrange
        let config = UISwipeActionsConfiguration(actions: [pin, edit])
        config.performsFirstActionWithFullSwipe = false
        return config
    }

    public func tableView(_ tableView: UITableView, accessoryButtonTappedForRowWith indexPath: IndexPath) {
        guard let index = commandIndex(for: indexPath) else { return }
        presentCommandEditor(editIndex: index)
    }
    
    // UITableViewDelegate
    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        
        // Use system default highlight without custom flashing animation
    
        if !isEditingMode {
            // Sending keyboard command
            if indexPath.row < specialEntries.count{
                handleSpecialEntries(index: indexPath.row)
            }
            else {
                let command = CommandManager.shared.getAllCommands()[indexPath.row-specialEntries.count]
                if command.cmdString.uppercased() == CommandManager.audioOutputCommand {
                    // Cycles in place: the sheet stays open, the row shows the new state.
                    specialEntryDelegate?.cycleAudioOutput?()
                    tableView.reloadRows(at: [indexPath], with: .none)
                    tableView.deselectRow(at: indexPath, animated: true)
                    return
                }
                if CommandManager.shared.isBuiltIn(command) {
                    // Performed by the stream once this sheet is gone (the keyboard
                    // can't become first responder under a dismissing modal).
                    let delegate = specialEntryDelegate
                    dismiss(animated: true) { delegate?.toggleSoftKeyboard?() }
                    return
                }
                sendKeyboardCommand(command)
            }
            dismiss(animated: true, completion: nil) // sending mode: one command per visit
        }
        else {
            let specialEntrySelected = indexPath.row < specialEntries.count
            let builtIn = commandIndex(for: indexPath).map { CommandManager.shared.isBuiltIn(CommandManager.shared.getAllCommands()[$0]) } ?? false
            addButton.isEnabled = !specialEntrySelected && !builtIn
            deleteButton.isEnabled = !specialEntrySelected && !builtIn
        }
    }

    // 支持排序
    public func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        return indexPath.row >= specialEntries.count
    }

    public func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        let commandsCount = CommandManager.shared.getAllCommands().count
        guard commandsCount > 0 else { return }
        let fromIndex = sourceIndexPath.row - specialEntries.count
        let toIndex = destinationIndexPath.row - specialEntries.count
        if fromIndex >= 0 && fromIndex < commandsCount && toIndex >= 0 && toIndex < commandsCount {
            CommandManager.shared.moveCommand(fromIndex: fromIndex, toIndex: toIndex)
        }
    }

    public func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        return .none
    }

    public func tableView(_ tableView: UITableView, targetIndexPathForMoveFromRowAt sourceIndexPath: IndexPath, toProposedIndexPath proposedIndexPath: IndexPath) -> IndexPath {
        let commandsCount = CommandManager.shared.getAllCommands().count
        // 如果没有可移动的命令，保持原位置
        guard commandsCount > 0 else { return sourceIndexPath }

        let minRow = specialEntries.count
        let maxRow = specialEntries.count + commandsCount - 1

        var clampedRow = proposedIndexPath.row
        if clampedRow < minRow { clampedRow = minRow }
        if clampedRow > maxRow { clampedRow = maxRow }
        return IndexPath(row: clampedRow, section: sourceIndexPath.section)
    }

    public func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool {
        return false
    }
    
    private func isSpecialEntrySelected() -> Bool {
        return self.tableView.indexPathForSelectedRow?.row ?? specialEntries.count+1 < specialEntries.count
    }
    
    private func handleSpecialEntries(index:Int){
        usleep(1000*100)
        dismiss(animated: true, completion: nil)
        switch specialEntries[index] as? String {
        case "widgetLayoutTool":
            specialEntryDelegate?.openWidgetLayoutTool!()
        case "bringUpSoftKeyboard":
            specialEntryDelegate?.bringUpSoftKeyboard?()
        case "enterPip":
            specialEntryDelegate?.enterPip?()
        case "toggleStatsOverlay":
            specialEntryDelegate?.toggleStatsOverlay?()
        case "disconnectAndQuitApp":
            specialEntryDelegate?.disconnectAndQuitApp?()
        default: break
        }
    }
    
    
    private func sendKeyboardCommand(_ cmd: RemoteCommand) {
        print("Sending key-value")
        let keyboardCmdStrings = CommandManager.shared.extractKeyStringsFromComboCommand(from: cmd.cmdString)
        CommandManager.shared.sendKeyComboCommand(keyboardCmdStrings: keyboardCmdStrings!)
    }
}
  
