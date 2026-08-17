//
//  ErrorLogViewController.swift
//  AltStore
//
//  Created by Riley Testut on 9/6/22.
//  Copyright © 2022 Riley Testut. All rights reserved.
//

@preconcurrency import UIKit
import SafariServices
import QuickLook
import CoreData

import Nuke

import QuickLook
import SwiftUI

final class ErrorLogViewController: UITableViewController, QLPreviewControllerDelegate
{
    private lazy var dataSource = self.makeDataSource()
    private var expandedErrorIDs = Set<NSManagedObjectID>()
    
    private var isScrolling = false {
        didSet {
            guard self.isScrolling != oldValue else { return }
            self.updateButtonInteractivity()
        }
    }

    private lazy var timeFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .none
        dateFormatter.timeStyle = .short
        return dateFormatter
    }()
    
    @IBOutlet private var exportLogButton: UIBarButtonItem?
    @IBOutlet private var clearLogButton: UIBarButtonItem!
    
    private var _exportedLogURL: URL?
    
    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }
    
    override func viewDidLoad()
    {
        super.viewDidLoad()
        
        self.tableView.dataSource = self.dataSource
        self.dataSource.contentView = self.tableView
        self.tableView.prefetchDataSource = self.dataSource
        
        self.exportLogButton?.activityIndicatorView.color = .white
        
        if #unavailable(iOS 15)
        {
            // Assign just clearLogButton to hide export button.
            self.navigationItem.rightBarButtonItems = [self.clearLogButton]
        }
        
//        // Adjust the width of the right bar button items
//        adjustRightBarButtonWidth()
    }
    
    
//    func adjustRightBarButtonWidth() {
//        // Access the current rightBarButtonItems
//        if let rightBarButtonItems = self.navigationItem.rightBarButtonItems {
//            for barButtonItem in rightBarButtonItems {
//                // Check if the button is a system button, and if so, replace it with a custom button
//                if barButtonItem.customView == nil {
//                    // Replace with a custom UIButton for each bar button item
//                    let customButton = UIButton(type: .custom)
//                    if let image = barButtonItem.image {
//                        customButton.setImage(image, for: .normal)
//                    }
//                    if let action = barButtonItem.action{
//                        customButton.addTarget(barButtonItem.target, action: action, for: .touchUpInside)
//                    }
//                    
//                    // Calculate the original size based on the system button
//                    let originalSize = customButton.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
//                    
//                    let scaleFactor = 0.7
//                    
//                    // Scale the size by 0.7 (70%)
//                    let scaledSize = CGSize(width: originalSize.width * scaleFactor, height: originalSize.height * scaleFactor)
//                    
//                    // Adjust the custom button's width
////                    customButton.frame.size = CGSize(width: 22, height: 22) // Adjust width as needed
//                    customButton.frame.size = scaledSize // Adjust width as needed
//                    
//                    // Set the custom button as the custom view for the UIBarButtonItem
//                    barButtonItem.customView = customButton
//                }
//            }
//        }
//    }
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?)
    {
        guard let loggedError = sender as? LoggedError, segue.identifier == "showErrorDetails" else { return }
        
        let navigationController = segue.destination as! UINavigationController
        
        let errorDetailsViewController = navigationController.viewControllers.first as! ErrorDetailsViewController
        errorDetailsViewController.loggedError = loggedError
    }
    
    @IBAction private func unwindFromErrorDetails(_ segue: UIStoryboardSegue)
    {
    }
}

private extension ErrorLogViewController
{
    func makeDataSource() -> RSTFetchedResultsTableViewPrefetchingDataSource<LoggedError, UIImage>
    {
        let fetchRequest = LoggedError.fetchRequest() as NSFetchRequest<LoggedError>
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \LoggedError.date, ascending: false)]
        fetchRequest.returnsObjectsAsFaults = false
        
        let fetchedResultsController = NSFetchedResultsController(fetchRequest: fetchRequest, managedObjectContext: DatabaseManager.shared.viewContext, sectionNameKeyPath: #keyPath(LoggedError.localizedDateString), cacheName: nil)
        
        let dataSource = RSTFetchedResultsTableViewPrefetchingDataSource<LoggedError, UIImage>(fetchedResultsController: fetchedResultsController)
        dataSource.proxy = self
        dataSource.rowAnimation = .fade
        dataSource.cellConfigurationHandler = { [weak self] (cell, loggedError, indexPath) in
            guard let self else { return }
            
            let cell = cell as! ErrorLogTableViewCell
            cell.dateLabel.text = self.timeFormatter.string(from: loggedError.date)
            cell.errorFailureLabel.text = loggedError.localizedFailure ?? NSLocalizedString("Operation Failed", comment: "")
            cell.errorCodeLabel.text = loggedError.error.localizedErrorCode
            
            let nsError = loggedError.error as NSError
            let errorDescription = [nsError.localizedDescription, nsError.localizedRecoverySuggestion].compactMap { $0 }.joined(separator: "\n\n")
            cell.errorDescriptionTextView.text = errorDescription
            cell.errorDescriptionTextView.maximumNumberOfLines = 5
            cell.errorDescriptionTextView.isCollapsed = !self.expandedErrorIDs.contains(loggedError.objectID)
            cell.errorDescriptionTextView.moreButton.addTarget(self, action: #selector(ErrorLogViewController.toggleCollapsingCell(_:)), for: .primaryActionTriggered)
            
            cell.appIconImageView.image = nil
            cell.appIconImageView.isIndicatingActivity = true
            cell.appIconImageView.layer.borderColor = UIColor.gray.cgColor
            
            let displayScale = (self.traitCollection.displayScale == 0.0) ? 1.0 : self.traitCollection.displayScale // 0.0 == "unspecified"
            cell.appIconImageView.layer.borderWidth = 1.0 / displayScale
                        
            cell.menuButton.isHidden = true
            cell.menuButton.menu = nil
            cell.selectionStyle = .none

            // Include errorDescriptionTextView's text in cell summary.
            cell.accessibilityLabel = [cell.errorFailureLabel.text, cell.dateLabel.text, cell.errorCodeLabel.text, cell.errorDescriptionTextView.text].compactMap { $0 }.joined(separator: ". ")
            
            // Group all paragraphs together into single accessibility element (otherwise, each paragraph is independently selectable).
            cell.errorDescriptionTextView.accessibilityLabel = cell.errorDescriptionTextView.text
        }
        dataSource.prefetchHandler = { (loggedError, indexPath, completion) in
            let iconURL = loggedError.storeApp?.iconURL
            
            Task.detached(priority: .background) {
                loggedError.managedObjectContext?.perform {
                    if let installedApp = loggedError.installedApp
                    {
                        installedApp.loadIcon { (result) in
                            switch result
                            {
                            case .failure(let error): completion(nil, error)
                            case .success(let image): completion(image, nil)
                            }
                        }
                    }
                    else if let iconURL = iconURL
                    {
                        ImagePipeline.shared.loadImage(with: iconURL, progress: nil) { result in
                            switch result
                            {
                            case .success(let response): completion(response.image, nil)
                            case .failure(let error): completion(nil, error)
                            }
                        }
                    }
                    else
                    {
                        // InstalledApp was probably deleted.
                        completion(nil, nil)
                    }
                }
            }
            return nil
        }
        dataSource.prefetchCompletionHandler = { (cell, image, indexPath, error) in
            let cell = cell as! ErrorLogTableViewCell
            cell.appIconImageView.image = image
            cell.appIconImageView.isIndicatingActivity = false
        }
        
        let placeholderView = RSTPlaceholderView()
        placeholderView.textLabel.text = NSLocalizedString("No Errors", comment: "")
        placeholderView.detailTextLabel.text = NSLocalizedString("Errors that occur when sideloading or refreshing apps will appear here.", comment: "")
        dataSource.placeholderView = placeholderView
        
        return dataSource
    }
}

private extension ErrorLogViewController
{
    @IBAction func toggleCollapsingCell(_ sender: UIButton)
    {
        let point = self.tableView.convert(sender.center, from: sender.superview)
        guard let indexPath = self.tableView.indexPathForRow(at: point), let cell = self.tableView.cellForRow(at: indexPath) as? ErrorLogTableViewCell else { return }
        
        let loggedError = self.dataSource.item(at: indexPath)
        
        if cell.errorDescriptionTextView.isCollapsed
        {
            self.expandedErrorIDs.remove(loggedError.objectID)
        }
        else
        {
            self.expandedErrorIDs.insert(loggedError.objectID)
        }
        
        self.tableView.performBatchUpdates {
            cell.layoutIfNeeded()
        }
    }
    
    
    enum LogView: String {
        case consoleLog = "console-log"

        // Method to get the QLPreviewController for this log type
        func getViewController(_ dataSource: QLPreviewControllerDataSource) -> QLPreviewController {
            let previewController = QLPreviewController()
            previewController.restorationIdentifier = self.rawValue
            previewController.dataSource = dataSource
            return previewController
        }
        
        func getLogPath() -> URL {
            let appDelegate = UIApplication.shared.delegate as! AppDelegate
            return appDelegate.consoleLog.logFileURL
        }
    }
    
    @IBAction func showConsoleLogs(_ sender: UIBarButtonItem) {
        // Create the SwiftUI ConsoleLogView with the URL
        let consoleLogView = ConsoleLogView(logURL: (UIApplication.shared.delegate as! AppDelegate).consoleLog.logFileURL)
        
        // Create the UIHostingController
        let consoleLogController = UIHostingController(rootView: consoleLogView)
        
        // Configure the bottom sheet presentation
        consoleLogController.modalPresentationStyle = .pageSheet
        if let sheet = consoleLogController.sheetPresentationController {
            sheet.detents = [.medium(), .large()]  // You can adjust the size of the sheet (medium/large)
            sheet.prefersGrabberVisible = true    // Optional: Shows a grabber at the top of the sheet
            sheet.selectedDetentIdentifier = .large  // Default size when presented
        }
        
        // Present the bottom sheet
        present(consoleLogController, animated: true, completion: nil)
    }
        
    @IBAction func clearLoggedErrors(_ sender: UIBarButtonItem)
    {
        let alertController = UIAlertController(title: NSLocalizedString("Are you sure you want to clear the error log?", comment: ""), message: nil, preferredStyle: .actionSheet)
        alertController.popoverPresentationController?.barButtonItem = sender
        alertController.addAction(.cancel)
        alertController.addAction(UIAlertAction(title: NSLocalizedString("Clear Error Log", comment: ""), style: .destructive) { _ in
            self.clearLoggedErrors()
        })
        self.present(alertController, animated: true)
    }
    
    func clearLoggedErrors()
    {
        DatabaseManager.shared.purgeLoggedErrors { result in
            do
            {
                try result.get()
            }
            catch
            {
                DispatchQueue.main.async {
                    let alertController = UIAlertController(title: NSLocalizedString("Failed to Clear Error Log", comment: ""), message: error.localizedDescription, preferredStyle: .alert)
                    alertController.addAction(.ok)
                    self.present(alertController, animated: true)
                }
            }
        }
    }
    
    func copyErrorMessage(for loggedError: LoggedError)
    {
        let nsError = loggedError.error as NSError
        let errorMessage = [nsError.localizedDescription, nsError.localizedRecoverySuggestion].compactMap { $0 }.joined(separator: "\n\n")
        
        UIPasteboard.general.string = errorMessage
    }
    
    func copyErrorCode(for loggedError: LoggedError)
    {
        let errorCode = loggedError.error.localizedErrorCode
        UIPasteboard.general.string = errorCode
    }
    
    func searchFAQ(for loggedError: LoggedError)
    {
        let staticURL = URL(string: "https://docs.sidestore.io/docs/troubleshooting/error-codes")!
        let safariViewController = SFSafariViewController(url: staticURL)
        safariViewController.preferredControlTintColor = .altPrimary
        self.present(safariViewController, animated: true)
    }

    func viewMoreDetails(for loggedError: LoggedError) {
        self.performSegue(withIdentifier: "showErrorDetails", sender: loggedError)
    }
}

extension ErrorLogViewController
{
    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration?
    {
        let loggedError = self.dataSource.item(at: indexPath)
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            return UIMenu(title: "", children: [
                UIAction(title: NSLocalizedString("Copy Error Message", comment: ""), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                    self?.copyErrorMessage(for: loggedError)
                },
                UIAction(title: NSLocalizedString("Copy Error Code", comment: ""), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                    self?.copyErrorCode(for: loggedError)
                },
                UIAction(title: NSLocalizedString("Search FAQ", comment: ""), image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in
                    self?.searchFAQ(for: loggedError)
                },
                UIAction(title: NSLocalizedString("View More Details", comment: ""), image: UIImage(systemName: "ellipsis.circle")) { [weak self] _ in
                    self?.viewMoreDetails(for: loggedError)
                },
            ])
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath)
    {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let cell = tableView.cellForRow(at: indexPath) as? ErrorLogTableViewCell else { return }
        
        if !cell.errorDescriptionTextView.moreButton.isHidden
        {
            self.toggleCollapsingCell(cell.errorDescriptionTextView.moreButton)
        }
    }
    
    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration?
    {
        let deleteAction = UIContextualAction(style: .destructive, title: NSLocalizedString("Delete", comment: "")) { _, _, completion in
            let loggedError = self.dataSource.item(at: indexPath)
            DatabaseManager.shared.persistentContainer.performBackgroundTask { context in
                do
                {
                    let loggedError = context.object(with: loggedError.objectID) as! LoggedError
                    context.delete(loggedError)
                    
                    try context.save()
                    DispatchQueue.main.async {
                        completion(true)
                    }
                }
                catch
                {
                    debugLog("[ALTLog] Failed to delete LoggedError \(loggedError.objectID): \(error)")
                    DispatchQueue.main.async {
                        completion(false)
                    }
                }
            }
        }
        
        let configuration = UISwipeActionsConfiguration(actions: [deleteAction])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }
    
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String?
    {
        let indexPath = IndexPath(row: 0, section: section)
        let loggedError = self.dataSource.item(at: indexPath)
        
        if Calendar.current.isDateInToday(loggedError.date)
        {
            return NSLocalizedString("Today", comment: "")
        }
        else
        {
            return loggedError.localizedDateString
        }
    }
}

extension ErrorLogViewController: QLPreviewControllerDataSource {
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        return 1
    }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem
    {
        guard let identifier = controller.restorationIdentifier,
              let logView = LogView(rawValue: identifier) else
        {
            let errorURL = FileManager.default.temporaryDirectory.appendingPathComponent("LogPreviewError.txt")
            let errorMessage = "Error: Failed to load log for '\(controller.restorationIdentifier ?? "unknown")'."
            try? errorMessage.write(to: errorURL, atomically: true, encoding: .utf8)
            return errorURL as QLPreviewItem
        }
        return logView.getLogPath() as QLPreviewItem
    }
}

extension ErrorLogViewController
{
    override func scrollViewWillBeginDragging(_ scrollView: UIScrollView)
    {
        self.isScrolling = true
    }
    override func scrollViewDidEndDecelerating(_ scrollView: UIScrollView)
    {
        self.isScrolling = false
    }
    override func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool)
    {
        guard !decelerate else { return }
        self.isScrolling = false
    }
    private func updateButtonInteractivity()
    {
        for case let cell as ErrorLogTableViewCell in self.tableView.visibleCells
        {
            if self.isScrolling
            {
                cell.menuButton.showsMenuAsPrimaryAction = false
            }
            else
            {
                cell.menuButton.showsMenuAsPrimaryAction = true
            }
        }
    }
}

//extension ErrorLogViewController: QLPreviewControllerDataSource, QLPreviewControllerDelegate
//{
//    func numberOfPreviewItems(in controller: QLPreviewController) -> Int
//    {
//        return 1
//    }
//    
//    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem
//    {
//        return (_exportedLogURL as? NSURL) ?? NSURL()
//    }
//    
//    func previewControllerDidDismiss(_ controller: QLPreviewController)
//    {
//        guard let exportedLogURL = _exportedLogURL else { return }
//        
//        let parentDirectory = exportedLogURL.deletingLastPathComponent()
//        
//        do
//        {
//            try FileManager.default.removeItem(at: parentDirectory)
//        }
//        catch
//        {
//            debugLog("Failed to remove temporary log directory \(parentDirectory.lastPathComponent). \(error.localizedDescription)")
//        }
//        
//        _exportedLogURL = nil
//    }
//}
