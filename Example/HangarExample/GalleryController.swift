import Hangar
import ImagePreview
import PhotosUI
import UIKit

/// A photo, as the viewer shows it (Flight's `PreviewContent`): the original and its edit, the edited picture shown
/// once there is one. An edit kept tells the viewer, which shows it at once.
@MainActor
final class Photo: PreviewContent {
    let original: UIImage
    private(set) var edit = HangarEdit()
    private(set) var edited: UIImage?
    private var changed: (@MainActor () -> Void)?

    init(_ original: UIImage) {
        self.original = original
    }

    var shown: UIImage { edited ?? original }

    func still() -> UIImage? { shown }

    func load(changed: @escaping @MainActor () -> Void) {
        self.changed = changed
    }

    func cancel() {
        changed = nil
    }

    /// The editor's preview at once; the full picture when it's drawn.
    func keep(_ result: HangarResult, then done: @escaping @MainActor () -> Void) {
        edit = result.edit
        edited = result.edit.isOriginal ? nil : result.preview
        changed?()
        done()
        guard !result.edit.isOriginal else { return }
        Task {
            guard let full = await result.render(), self.edit == result.edit else { return }
            self.edited = full
            self.changed?()
            done()
        }
    }
}

/// The example: photos in a grid (Example/Pictures, and any picked with +); one tapped opens in Flight's viewer, whose
/// Edit opens Hangar on it, flying from the viewer's picture and back into it.
@MainActor
final class GalleryController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate, @preconcurrency PHPickerViewControllerDelegate {
    private var photos: [Photo] = []
    private var collection: UICollectionView!

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Hangar"
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .add, primaryAction: UIAction { [weak self] _ in self?.pick() })
        collection = UICollectionView(frame: view.bounds, collectionViewLayout: Self.layout())
        collection.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collection.dataSource = self
        collection.delegate = self
        collection.register(Cell.self, forCellWithReuseIdentifier: "cell")
        view.addSubview(collection)
        loadBundled()
        #if DEBUG
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.runLaunchArguments() }
        #endif
    }

    #if DEBUG
    /// For looking at the editor on a device without touching it: `-open N` opens photo N, `-edit 1` its editor a
    /// second later, `-mode filters` in Filters, `-exposure 0.4` and `-filter vivid` with that edit.
    private func runLaunchArguments() {
        let defaults = UserDefaults.standard
        guard let index = defaults.object(forKey: "open") as? Int ?? (defaults.string(forKey: "open").flatMap(Int.init)),
              photos.indices.contains(index) else { return }
        open(at: index)
        guard defaults.bool(forKey: "edit") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, let preview = self.shownPreview else { return }
            var edit = HangarEdit()
            if let exposure = defaults.string(forKey: "exposure").flatMap(Double.init) { edit.set("exposure", to: exposure) }
            edit.filter = defaults.string(forKey: "filter")
            self.edit(in: preview, startingWith: edit, mode: defaults.string(forKey: "mode").map(HangarMode.init) ?? .adjust)
        }
    }
    #endif

    private static func layout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { _, environment in
            let columns = environment.container.effectiveContentSize.width > 700 ? 5 : 3
            let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1 / CGFloat(columns)), heightDimension: .fractionalWidth(1 / CGFloat(columns))))
            item.contentInsets = NSDirectionalEdgeInsets(top: 1, leading: 1, bottom: 1, trailing: 1)
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalWidth(1 / CGFloat(columns))),
                                                           repeatingSubitem: item, count: columns)
            return NSCollectionLayoutSection(group: group)
        }
    }

    private func loadBundled() {
        guard let folder = Bundle.main.url(forResource: "Pictures", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        photos = files.filter { $0.pathExtension == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { UIImage(contentsOfFile: $0.path) }.map(Photo.init)
        collection.reloadData()
    }

    // MARK: Grid

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        photos.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath) as! Cell
        cell.show(photos[indexPath.item].shown)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        open(at: indexPath.item)
    }

    private func cell(_ index: Int) -> Cell? {
        collection.cellForItem(at: IndexPath(item: index, section: 0)) as? Cell
    }

    // MARK: Viewer

    private func open(at index: Int) {
        let photos = photos
        let preview = ImagePreviewController(count: photos.count, index: index) { i in
            PreviewMedia.content(photos[i])
        } source: { [weak self] i in
            self?.cell(i).map { PreviewSource(view: $0.picture) }
        }
        preview.onIndexChange = { [weak self] i in
            self?.collection.scrollToItem(at: IndexPath(item: i, section: 0), at: .centeredVertically, animated: false)
        }
        let edit = UIBarButtonItem(image: UIImage(systemName: "slider.horizontal.3"), primaryAction: UIAction { [weak self, weak preview] _ in
            guard let self, let preview else { return }
            self.edit(in: preview)
        })
        edit.accessibilityLabel = "Edit"
        preview.page.toolbarItems = [.flexibleSpace(), edit, .flexibleSpace()]
        preview.present(from: view)
        shownPreview = preview
    }

    private weak var shownPreview: ImagePreviewController?

    /// Hangar on the photo the viewer shows, flying out of it: the viewer fits it to the screen.
    private func edit(in preview: ImagePreviewController, startingWith edit: HangarEdit? = nil, mode: HangarMode = .adjust) {
        let index = preview.index
        let photo = photos[index]
        let page = preview.page
        let editor = HangarEditor(image: photo.original, edit: edit ?? photo.edit)
        editor.mode = mode
        // The app's own: in More, after Photos'.
        editor.actions = [.removeBackground]
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "testSteps") { editor.actions += [.testInvert, .testExpand] }
        #endif
        editor.onDone = { [weak self] result in
            photo.keep(result) { self?.collection.reloadItems(at: [IndexPath(item: index, section: 0)]) }
        }
        let frame = HangarEditor.fit(photo.shown.size, in: page.view.bounds, scale: page.view.window?.screen.scale ?? 2)
        editor.present(from: page, source: HangarSource(view: page.view, frame: frame))
    }

    // MARK: Picking

    private func pick() {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 0
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        let providers = results.map(\.itemProvider).filter { $0.canLoadObject(ofClass: UIImage.self) }
        Task {
            for provider in providers {
                let image = await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
                    provider.loadObject(ofClass: UIImage.self) { object, _ in
                        continuation.resume(returning: object as? UIImage)
                    }
                }
                guard let image else { continue }
                photos.append(Photo(image))
                collection.insertItems(at: [IndexPath(item: photos.count - 1, section: 0)])
            }
        }
    }
}

final class Cell: UICollectionViewCell {
    let picture = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        picture.frame = contentView.bounds
        picture.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(picture)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ image: UIImage) {
        picture.image = image.preparingThumbnail(of: CGSize(width: 400, height: 400 * image.size.height / max(image.size.width, 1))) ?? image
    }
}
