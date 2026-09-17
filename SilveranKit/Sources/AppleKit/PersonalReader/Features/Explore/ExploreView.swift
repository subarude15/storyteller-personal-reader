#if os(iOS) || os(macOS)
import SwiftUI
import SilveranKit

// MARK: - Explore Tab (Lawful Transports Only)
//
// Sections:
//  1. Public Catalogs (OPDS allow-list)
//  2. Your Catalogs (user-added OPDS)
//  3. Add via Link (direct https)
//  4. BYO Debrid Link (user-supplied link after auth)
//  5. Wishlist / Search (Open Library + Hardcover, metadata-only)
//  6. More like this (library-only until Add to Library)
//
// Every download is gated behind an explicit “Add to Library” tap that names
// the lawful transport. No auto-download, no DRM strip, no bundled index.

public struct ExploreView: View {
    @Environment(MediaViewModel.self) private var mediaViewModel

    @State private var publicEntries: [OPDSEntry] = []
    @State private var isLoadingPublic = false
    @State private var userCatalogURLString = ""
    @State private var userCatalogName = ""
    @State private var userEntries: [OPDSEntry] = []
    @State private var isLoadingUser = false
    @State private var userCatalogError: String?

    @State private var directLinkString = ""
    @State private var directLinkError: String?
    @State private var isDownloadingDirect = false

    @State private var byoLinkString = ""
    @State private var byoProvider: BYOProvider = .realDebrid
    @State private var byoTokenInput = ""
    @State private var showBYOAuth = false
    @State private var byoError: String?
    @State private var byoResolvedURL: URL?

    @State private var wishlistQuery = ""
    @State private var wishlistItems: [WishlistItem] = []
    @State private var isSearchingWishlist = false

    @State private var selectedCatalogID: String?

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                publicCatalogsSection
                yourCatalogsSection
                directLinkSection
                byoSection
                wishlistSection
                moreLikeThisSection
                policyFooter
            }
            .navigationTitle("Explore")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .task { await loadPublicIfNeeded() }
    }

    // MARK: - 1) Public Catalogs

    private var publicCatalogsSection: some View {
        Section {
            ForEach(OPDSCatalogs.builtIn) { catalog in
                Button {
                    Task { await loadPublicCatalog(catalog) }
                } label: {
                    catalogRow(catalog)
                }
                .foregroundStyle(.primary)
            }
            if isLoadingPublic { ProgressView().frame(maxWidth: .infinity) }
            if !publicEntries.isEmpty {
                ForEach(publicEntries, id: \.id) { entry in
                    opdsEntryRow(entry)
                }
            }
        } header: {
            Label("Public Catalogs", systemImage: "books.vertical")
        } footer: {
            Text("Curated public OPDS/Atom catalogs — Project Gutenberg, Standard Ebooks, Internet Archive, Feedbooks and Open Library. All are https and publisher-authorized. Add your own library catalog below.")
                .font(.caption)
        }
    }

    private func catalogRow(_ catalog: OPDSCatalog) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(catalog.name).font(.headline)
                Text(catalog.provenance).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func opdsEntryRow(_ entry: OPDSEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.title).font(.subheadline.weight(.semibold))
            if let author = entry.author { Text(author).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Text(entry.provenance.badgeText).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12)).clipShape(Capsule())
                Spacer()
                if let link = entry.acquisitionLinks.first {
                    addToLibraryButton(label: "Add to Library", provenance: entry.provenance) {
                        Task { await importOPDSLink(link, entry: entry) }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - 2) Your Catalogs

    private var yourCatalogsSection: some View {
        Section {
            TextField("https:// your library OPDS / Atom URL", text: $userCatalogURLString)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Display name (optional)", text: $userCatalogName)
                .textInputAutocapitalization(.words)
            Button {
                Task { await addUserCatalog() }
            } label: {
                Label("Add Catalog", systemImage: "link.badge.plus")
            }
            .disabled(userCatalogURLString.trimmingCharacters(in: .whitespaces).isEmpty || isLoadingUser)
            if isLoadingUser { ProgressView().frame(maxWidth: .infinity) }
            if let err = userCatalogError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            ForEach(userEntries, id: \.id) { entry in
                opdsEntryRow(entry)
            }
            // Saved user catalogs
            let saved = OPDSCatalogStore.loadUserCatalogs()
            if !saved.isEmpty {
                ForEach(saved) { cat in
                    Button(cat.name) { Task { await loadPublicCatalog(cat) } }
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Label("Your Catalogs", systemImage: "link.badge.plus")
        } footer: {
            Text("Paste an OPDS/Atom URL you control or have access to — your public library, publisher store, or self-hosted Komga / Kavita / Calibre-Web. We validate https and reject banned hosts. Nothing is bundled.")
                .font(.caption)
        }
    }

    // MARK: - 3) Direct Link

    private var directLinkSection: some View {
        Section {
            TextField("https://…/book.epub  or  …/audio.m4b", text: $directLinkString)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if let err = directLinkError { Text(err).font(.caption).foregroundStyle(.red) }
            Button {
                Task { await downloadDirectLink() }
            } label: {
                Label(isDownloadingDirect ? "Downloading…" : "Add via Link", systemImage: "link")
            }
            .disabled(directLinkString.trimmingCharacters(in: .whitespaces).isEmpty || isDownloadingDirect)
            if isDownloadingDirect { ProgressView().frame(maxWidth: .infinity) }
        } header: {
            Label("Add via Link", systemImage: "link")
        } footer: {
            Text("Paste a direct https link to an .epub, .cbz, .m4b, .m4a, .mp3, or .zip you have the right to download. We check scheme, extension, and Content-Type before fetching. No scraping, no DRM removal.")
                .font(.caption)
        }
    }

    // MARK: - 4) BYO

    private var byoSection: some View {
        Section {
            Picker("Provider", selection: $byoProvider) {
                ForEach(BYOProvider.allCases) { p in Text(p.displayName).tag(p) }
            }
            .pickerStyle(.menu)
            Button(showBYOAuth ? "Hide provider auth" : "Connect provider…") { showBYOAuth.toggle() }
            if showBYOAuth {
                SecureField("\(byoProvider.displayName) token / API key", text: $byoTokenInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save Token") {
                    Task { await BYOTransportService.shared.setToken(byoTokenInput, for: byoProvider); byoTokenInput = "" }
                }
                .disabled(byoTokenInput.trimmingCharacters(in: .whitespaces).isEmpty)
                Text("Token is stored locally (Keychain when available) and used only to resolve the single link you paste below.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextField("Paste a single magnet: or https:// link you own", text: $byoLinkString)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if let err = byoError { Text(err).font(.caption).foregroundStyle(.red) }
            if let resolved = byoResolvedURL {
                Text("Resolved: \(resolved.absoluteString)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Button {
                Task { await resolveBYO() }
            } label: {
                Label("Resolve & Add to Library", systemImage: "personalhotspot")
            }
            .disabled(byoLinkString.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Label("Add from Your Debrid Link (BYO)", systemImage: "personalhotspot")
        } footer: {
            Text("Bring your own debrid/torrent link. Connect your own Real-Debrid / AllDebrid / Premiumize account, then paste one link you supply. The app resolves only that one link — there is no bundled index search or default tracker list.")
                .font(.caption)
        }
    }

    // MARK: - 5) Wishlist / Search

    private var wishlistSection: some View {
        Section {
            TextField("Search wishlist — title or author", text: $wishlistQuery)
                .textInputAutocapitalization(.never)
                .onSubmit { Task { await searchWishlist() } }
            Button("Search") { Task { await searchWishlist() } }
                .disabled(wishlistQuery.trimmingCharacters(in: .whitespaces).count < 2 || isSearchingWishlist)
            if isSearchingWishlist { ProgressView().frame(maxWidth: .infinity) }
            ForEach(wishlistItems) { item in
                wishlistRow(item)
            }
        } header: {
            Label("Wishlist / Search (Metadata Only)", systemImage: "magnifyingglass")
        } footer: {
            Text("Open Library and Hardcover results are wishlist/search only. They show books you don’t own with a “Not in Library” badge. Tap the book to see More like this from your library. Download only via a lawful transport above (Add to Library).")
                .font(.caption)
        }
    }

    private func wishlistRow(_ item: WishlistItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title).font(.subheadline.weight(.semibold))
            if !item.authors.isEmpty { Text(item.authors.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Text(item.source.rawValue).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12)).clipShape(Capsule())
                Text(item.isInLibrary ? "In Library" : "Not in Library")
                    .font(.caption2).foregroundStyle(item.isInLibrary ? .green : .orange)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background((item.isInLibrary ? Color.green : Color.orange).opacity(0.12)).clipShape(Capsule())
                Spacer()
                if item.isInLibrary {
                    Text("More like this").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Menu("Add to Library…") {
                        Button("via Public Catalog") {}
                        Button("via Your Catalog") {}
                        Button("via Direct Link") {}
                        Button("via Your Debrid Link") {}
                    }
                    .font(.caption)
                }
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - 6) More like this (library-only)

    private var moreLikeThisSection: some View {
        Section {
            let library = mediaViewModel.library.bookMetaData
            if library.isEmpty {
                Text("Your library is empty — More like this will appear after you add a book via Add to Library.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                // Demo: show More like this for the first book; real app wires selection from wishlist tap
                let first = library.first!
                let recs = ExploreMoreLikeThisService.moreLike(first, in: library)
                if recs.isEmpty {
                    Text("No close matches for “\(first.title)” in your library yet.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("More like “\(first.title)” — from Your Library").font(.caption.weight(.semibold))
                    ForEach(recs, id: \.id) { book in
                        HStack {
                            Text(book.title).font(.caption)
                            Spacer()
                            Text(book.authors?.first?.name ?? book.creators?.first?.name ?? "").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Label("More like this — From Your Library Only", systemImage: "sparkles.rectangle.stack")
        } footer: {
            Text("This section never calls the network. Recommendations are author / series / tag overlap within your library. It stays library-only until you Add to Library via a lawful transport.")
                .font(.caption)
        }
    }

    private var policyFooter: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Lawful boundary").font(.caption.weight(.semibold))
                Text("Explore never bundles pirate indexes, never scrapes Audible logins, and never strips DRM. Acquisition is only via: public OPDS/Atom, your OPDS, a direct https link you paste, or a single BYO debrid/torrent link you supply after authenticating to your own provider. Open Library / Hardcover are metadata-only (wishlist/search).")
                    .font(.caption).foregroundStyle(.secondary)
                Link("What not to copy: PlayTorrio (pirate bundle)", destination: URL(string: "https://github.com/ayman708-UX/PlayTorrioV3")!)
                    .font(.caption2)
            }
        }
    }

    // MARK: - Helpers

    private func addToLibraryButton(label: String, provenance: AcquisitionProvenance, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(provenance.badgeText)
    }

    // MARK: - Actions (stubs — wire to BookServiceActor / FolderSourceActor in real integration)

    private func loadPublicIfNeeded() async {
        // Intentionally not auto-loading all catalogs; user taps to browse.
    }

    private func loadPublicCatalog(_ catalog: OPDSCatalog) async {
        isLoadingPublic = true
        defer { isLoadingPublic = false }
        do {
            let entries = try await OPDSCatalogService.shared.fetchCatalog(catalog)
            publicEntries = entries
            selectedCatalogID = catalog.id
        } catch {
            // Surface to UI; do not fall back to pirate hosts
            publicEntries = []
        }
    }

    private func addUserCatalog() async {
        userCatalogError = nil
        isLoadingUser = true
        defer { isLoadingUser = false }
        do {
            let url = try OPDSCatalogStore.validateUserURLString(userCatalogURLString)
            let catalog = OPDSCatalog(id: "user-\(url.absoluteString.hashValue)", name: userCatalogName.isEmpty ? (url.host ?? "Your Catalog") : userCatalogName, url: url, isUserAdded: true, provenance: "Your catalog — \(url.host ?? "")")
            let entries = try await OPDSCatalogService.shared.fetchCatalog(catalog)
            userEntries = entries
            // Persist
            var saved = OPDSCatalogStore.loadUserCatalogs()
            if !saved.contains(where: { $0.url == url }) {
                saved.append(catalog)
                OPDSCatalogStore.saveUserCatalogs(saved)
            }
            userCatalogError = nil
        } catch let e as ExploreAcquisitionError {
            userCatalogError = e.localizedDescription
        } catch {
            userCatalogError = error.localizedDescription
        }
    }

    private func importOPDSLink(_ link: OPDSAcquisitionLink, entry: OPDSEntry) async {
        // Real flow: download link.href (https only, already validated) then
        // BookServiceActor.shared.createBookSource / acceptBook on the user's chosen source.
        // Never strip DRM; never rewrite to a pirate mirror.
        _ = link
        _ = entry
    }

    private func downloadDirectLink() async {
        directLinkError = nil
        isDownloadingDirect = true
        defer { isDownloadingDirect = false }
        do {
            let validated = try await DirectLinkIngestService.shared.validate(urlString: directLinkString)
            try await DirectLinkIngestService.shared.probe(validated)
            let data = try await DirectLinkIngestService.shared.download(validated)
            _ = data // hand to BookServiceActor / FolderSourceActor acceptBook
        } catch let e as ExploreAcquisitionError {
            directLinkError = e.localizedDescription
        } catch {
            directLinkError = error.localizedDescription
        }
    }

    private func resolveBYO() async {
        byoError = nil
        byoResolvedURL = nil
        do {
            let resolved = try await BYOTransportService.shared.resolveUserLink(byoLinkString, using: byoProvider)
            byoResolvedURL = resolved
            // Next step is DirectLinkIngestService-style download from `resolved` — still user-supplied, still https
        } catch let e as ExploreAcquisitionError {
            byoError = e.localizedDescription
        } catch {
            byoError = error.localizedDescription
        }
    }

    private func searchWishlist() async {
        isSearchingWishlist = true
        defer { isSearchingWishlist = false }
        let library = mediaViewModel.library.bookMetaData
        wishlistItems = await ExploreWishlistService.shared.search(query: wishlistQuery, library: library)
    }
}
#endif
