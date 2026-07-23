import SwiftUI
import Charts
import NovaDomain
import PhotosUI
#if canImport(UIKit)
import UIKit
#endif

/// Remy-exclusive Kitchen destination (Claude → Coding pattern).
public struct RemyKitchenView: View {
    @Bindable var kitchen: RemyKitchenViewModel
    @Bindable var conversation: ConversationViewModel
    var embedded: Bool

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var mealPhotoItems: [PhotosPickerItem] = []
    @State private var editingPantry: PantryItem?
    @State private var showNewPantry = false
    @State private var editingRecipe: Recipe?
    @State private var showNewRecipe = false
    @State private var showImportRecipe = false
    @State private var showNewShopping = false
    @State private var newShoppingName = ""
    @State private var mealEditor: MealSlotEditor?
    @State private var mealLogDraft = ""
    @State private var importURL = ""
    @State private var importPaste = ""

    public init(kitchen: RemyKitchenViewModel, conversation: ConversationViewModel, embedded: Bool = false) {
        self.kitchen = kitchen
        self.conversation = conversation
        self.embedded = embedded
    }

    public var body: some View {
        Group {
            if embedded {
                content
            } else {
                NavigationStack { content }
            }
        }
        .task { await kitchen.load() }
        .onAppear { kitchen.setScreenVisible(true) }
        .onDisappear { kitchen.setScreenVisible(false) }
    }

    /// Warm terracotta identity for Remy's kitchen.
    static let terracotta = Color(red: 0.80, green: 0.40, blue: 0.20)

    private var content: some View {
        Group {
            if kitchen.cookingSession != nil {
                cookModeHUD
            } else {
                kitchenList
            }
        }
        .navigationTitle(embedded ? "Kitchen" : "Remy Kitchen")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Self.terracotta)
        .sheet(item: $editingPantry) { item in
            PantryEditorSheet(item: item) { saved in
                Task { await kitchen.savePantryItem(saved) }
            }
        }
        .sheet(isPresented: $showNewPantry) {
            PantryEditorSheet(item: PantryItem(name: "")) { saved in
                Task { await kitchen.savePantryItem(saved) }
            }
        }
        .sheet(item: $editingRecipe) { recipe in
            RecipeEditorSheet(recipe: recipe) { saved in
                Task { await kitchen.saveRecipe(saved) }
            }
        }
        .sheet(isPresented: $showNewRecipe) {
            RecipeEditorSheet(recipe: Recipe(title: "", steps: [""])) { saved in
                Task { await kitchen.saveRecipe(saved) }
            }
        }
        .sheet(isPresented: $showImportRecipe) {
            RecipeImportSheet(
                urlText: $importURL,
                pasteText: $importPaste,
                isImporting: kitchen.isImportingRecipe,
                onImport: {
                    Task {
                        await kitchen.importRecipe(
                            url: importURL.isEmpty ? nil : importURL,
                            text: importPaste.isEmpty ? nil : importPaste
                        )
                        if kitchen.recipeImportPreview != nil {
                            showImportRecipe = false
                            importURL = ""
                            importPaste = ""
                        }
                    }
                }
            )
        }
        .sheet(item: $kitchen.recipeImportPreview, onDismiss: {
            kitchen.recipeImportPreview = nil
        }) { recipe in
            RecipeEditorSheet(recipe: recipe) { saved in
                Task {
                    await kitchen.saveRecipe(saved)
                    kitchen.recipeImportPreview = nil
                }
            }
        }
        .sheet(item: $mealEditor) { editor in
            MealSlotSheet(
                editor: editor,
                recipes: kitchen.recipes,
                onSave: { day, kind, recipeId, note in
                    Task { await kitchen.setMealSlot(dayOffset: day, kind: kind, recipeId: recipeId, note: note) }
                },
                onClear: { day, kind in
                    Task { await kitchen.clearMealSlot(dayOffset: day, kind: kind) }
                }
            )
        }
        .sheet(item: $kitchen.mealLogEditor) { draft in
            MealLogEditorSheet(
                draft: draft,
                hits: kitchen.foodLookupHits,
                isLookingUp: kitchen.isLookingUpFood,
                onCancel: { kitchen.cancelMealLogEditor() },
                onSave: { saved in
                    Task { await kitchen.saveMealLogEditor(saved) }
                },
                onLookup: { query, barcode in
                    Task { await kitchen.lookupFood(query: query, barcode: barcode) }
                },
                onSelectHit: { hit in
                    kitchen.applyFoodHit(hit)
                }
            )
        }
    }

    private var kitchenList: some View {
        List {
            Section {
                NovaUI.AgentVoiceChatBar(conversation: conversation)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowBackground(Color.clear)
            }

            Section {
                VStack(spacing: 10) {
                    if let session = kitchen.cookingSession {
                        cookingBanner(session)
                    }
                    sectionChips
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                .listRowBackground(Color.clear)
            }

            if !kitchen.statusMessage.isEmpty {
                Section {
                    Label(kitchen.statusMessage, systemImage: "sparkles")
                        .font(.footnote)
                        .foregroundStyle(Self.terracotta)
                }
            }

            switch kitchen.selectedSection {
            case .pantry: pantrySections
            case .scan: scanSections
            case .recipes: recipeSections
            case .shopping: shoppingSections
            case .meals: mealSections
            case .profile: profileSections
            }
        }
    }

    /// Full-bleed hands-friendly cook HUD (large step + timer ring).
    private var cookModeHUD: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let session = kitchen.cookingSession, let recipe = kitchen.cookingRecipe {
                    let idx = session.currentStepIndex
                    let total = max(1, recipe.steps.count)
                    VStack(alignment: .leading, spacing: 12) {
                        Label(session.recipeTitle, systemImage: "frying.pan.fill")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(.white.opacity(0.85))
                        HStack(spacing: 4) {
                            ForEach(0..<total, id: \.self) { step in
                                Capsule()
                                    .fill(step <= idx ? Color.white : Color.white.opacity(0.25))
                                    .frame(height: 5)
                            }
                        }
                        Text("Step \(idx + 1) of \(total)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white.opacity(0.8))
                        Text(recipe.steps.indices.contains(idx) ? recipe.steps[idx] : "No steps")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        LinearGradient(
                            colors: [Self.terracotta, Color(red: 0.65, green: 0.28, blue: 0.15)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 20)
                    )

                    cookTimerCard

                    HStack(spacing: 12) {
                        Button("Back") { Task { await kitchen.cookingPrevious() } }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                        Button("Next") { Task { await kitchen.cookingNext() } }
                            .buttonStyle(.borderedProminent)
                            .frame(maxWidth: .infinity)
                    }
                    Button(role: .destructive) {
                        Task { await kitchen.endCooking() }
                    } label: {
                        Label("End cook mode", systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    if !recipe.ingredients.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("INGREDIENTS")
                                .font(.caption.weight(.heavy))
                                .foregroundStyle(.secondary)
                            ForEach(recipe.ingredients) { ing in
                                Button {
                                    Task { await kitchen.toggleCookIngredient(ing) }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: kitchen.isCookIngredientChecked(ing) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(kitchen.isCookIngredientChecked(ing) ? .green : .secondary)
                                        Text(ing.quantity.map { "\($0) · \(ing.name)" } ?? ing.name)
                                            .font(.subheadline)
                                            .strikethrough(kitchen.isCookIngredientChecked(ing))
                                            .foregroundStyle(kitchen.isCookIngredientChecked(ing) ? .secondary : .primary)
                                        Spacer()
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                if !kitchen.statusMessage.isEmpty {
                    Text(kitchen.statusMessage)
                        .font(.footnote)
                        .foregroundStyle(Self.terracotta)
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var cookTimerCard: some View {
        VStack(spacing: 10) {
            if kitchen.cookTimerRemainingSeconds > 0 {
                ZStack {
                    Circle()
                        .stroke(Self.terracotta.opacity(0.2), lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: cookTimerFraction)
                        .stroke(Self.terracotta, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: kitchen.cookTimerRemainingSeconds)
                    VStack(spacing: 0) {
                        Text("\(kitchen.cookTimerRemainingSeconds)")
                            .font(.system(size: 40, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                        Text(kitchen.primaryCookTimer?.label.uppercased() ?? "TIMER")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 130, height: 130)
                HStack(spacing: 12) {
                    Button("Skip") { Task { await kitchen.skipCookTimer() } }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                    Button("+30s") { Task { await kitchen.addCookTimer() } }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                }
            } else {
                if let stepSeconds = kitchen.currentStepTimerSeconds {
                    Button {
                        Task { await kitchen.startCookTimer(seconds: stepSeconds) }
                    } label: {
                        Label("Start step timer · \(Self.durationLabel(stepSeconds))", systemImage: "timer")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                }
                HStack(spacing: 10) {
                    Button {
                        Task { await kitchen.startCookTimer(seconds: 60) }
                    } label: {
                        Label("1 min", systemImage: "timer")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        Task { await kitchen.startCookTimer(seconds: 300) }
                    } label: {
                        Label("5 min", systemImage: "timer")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private var cookTimerFraction: CGFloat {
        let total = max(1, kitchen.primaryCookTimer?.seconds ?? 60)
        return CGFloat(kitchen.cookTimerRemainingSeconds) / CGFloat(total)
    }

    private var sectionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(RemyKitchenViewModel.Section.allCases) { section in
                    Button {
                        withAnimation(.snappy) { kitchen.selectedSection = section }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: section.systemImage)
                                .font(.caption)
                            Text(section.title)
                                .font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            kitchen.selectedSection == section
                                ? Self.terracotta
                                : Self.terracotta.opacity(0.10),
                            in: Capsule()
                        )
                        .foregroundStyle(
                            kitchen.selectedSection == section ? .white : Self.terracotta
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Always-visible strip while cook mode is live, tappable to jump to Recipes.
    private func cookingBanner(_ session: CookingSession) -> some View {
        Button {
            withAnimation(.snappy) { kitchen.selectedSection = .recipes }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "frying.pan.fill")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Cooking now")
                        .font(.caption2.weight(.bold))
                        .opacity(0.85)
                    Text(session.recipeTitle)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .opacity(0.7)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                LinearGradient(
                    colors: [Self.terracotta, Color(red: 0.65, green: 0.28, blue: 0.15)],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 14)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Pantry

    @ViewBuilder
    private var pantrySections: some View {
        Section {
            TextField("Search pantry", text: $kitchen.pantryQuery)
            Button {
                showNewPantry = true
            } label: {
                Label("Add item", systemImage: "plus")
            }
        }

        if kitchen.filteredPantry.isEmpty {
            Section {
                Text("Pantry is empty. Add items or scan your fridge.")
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(kitchen.pantryGroupedByLocation, id: \.0) { location, items in
                Section(location.rawValue.capitalized) {
                    ForEach(items) { item in
                        Button {
                            editingPantry = item
                        } label: {
                            PantryRow(item: item)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task { await kitchen.deletePantryItem(item) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Scan

    @ViewBuilder
    private var scanSections: some View {
        Section("Fridge photo") {
            PhotosPicker(selection: $photoItems, maxSelectionCount: 1, matching: .images) {
                Label(
                    kitchen.isScanning ? "Analyzing…" : "Choose fridge photo",
                    systemImage: "photo.on.rectangle"
                )
            }
            .disabled(kitchen.isScanning)
            .onChange(of: photoItems) { _, items in
                guard let item = items.first else { return }
                Task {
                    #if canImport(UIKit)
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data),
                       let jpeg = image.jpegData(compressionQuality: 0.85) {
                        await kitchen.scanPhotoData(jpeg, mimeType: "image/jpeg")
                    }
                    #endif
                    photoItems = []
                }
            }

            Button {
                Task { await kitchen.scanWithGlasses() }
            } label: {
                Label("Scan fridge with glasses", systemImage: "eyeglasses")
            }
            .disabled(kitchen.isScanning)
        }

        Section("Meal photo") {
            Text("Scan a plate to estimate calories and macros, then confirm meal type and details before saving. Totals show under Profile → Today.")
                .font(.caption)
                .foregroundStyle(.secondary)

            PhotosPicker(selection: $mealPhotoItems, maxSelectionCount: 1, matching: .images) {
                Label(
                    kitchen.isScanning ? "Analyzing…" : "Scan meal from photo",
                    systemImage: "camera.fill"
                )
            }
            .disabled(kitchen.isScanning)
            .onChange(of: mealPhotoItems) { _, items in
                guard let item = items.first else { return }
                Task {
                    #if canImport(UIKit)
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data),
                       let jpeg = image.jpegData(compressionQuality: 0.85) {
                        await kitchen.logMealPhotoData(jpeg, mimeType: "image/jpeg")
                    }
                    #endif
                    mealPhotoItems = []
                }
            }

            Button {
                Task { await kitchen.logMealWithGlasses() }
            } label: {
                Label("Scan meal with glasses", systemImage: "eyeglasses")
            }
            .disabled(kitchen.isScanning)
        }

        if let scan = kitchen.lastScan {
            Section("Detected") {
                if scan.detected.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                } else {
                    ForEach(scan.detected) { item in
                        ScanItemRow(item: item)
                    }
                }
            }
            Section("Low / unclear") {
                if scan.lowOrUnclear.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                } else {
                    ForEach(scan.lowOrUnclear) { item in
                        ScanItemRow(item: item)
                    }
                }
            }
            Section("Missing staples") {
                if scan.missingStaples.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                } else {
                    ForEach(scan.missingStaples, id: \.self) { name in
                        Text(name)
                    }
                }
            }
            if let notes = scan.notes, !notes.isEmpty {
                Section("Notes") { Text(notes) }
            }
            Section {
                Button {
                    Task { await kitchen.applyLastScanToPantry() }
                } label: {
                    Label("Apply to pantry", systemImage: "checkmark.circle")
                }
            }
        }
    }

    // MARK: - Recipes

    @ViewBuilder
    private var recipeSections: some View {
        if let session = kitchen.cookingSession, let recipe = kitchen.cookingRecipe {
            Section("Cook mode — \(session.recipeTitle)") {
                let idx = session.currentStepIndex
                let total = max(1, recipe.steps.count)
                HStack(spacing: 4) {
                    ForEach(0..<total, id: \.self) { step in
                        Capsule()
                            .fill(step <= idx ? Self.terracotta : Self.terracotta.opacity(0.15))
                            .frame(height: 4)
                    }
                }
                .padding(.vertical, 2)
                Text("Step \(idx + 1) of \(total)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Self.terracotta)
                Text(recipe.steps.indices.contains(idx) ? recipe.steps[idx] : "No steps")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                HStack {
                    Button("Back") { Task { await kitchen.cookingPrevious() } }
                    Spacer()
                    Button("Next") { Task { await kitchen.cookingNext() } }
                        .buttonStyle(.borderedProminent)
                    Button("End", role: .destructive) { Task { await kitchen.endCooking() } }
                }
            }
        }

        Section {
            Button { showNewRecipe = true } label: {
                Label("New recipe", systemImage: "plus")
            }
            Button { showImportRecipe = true } label: {
                Label("Import from URL or paste", systemImage: "square.and.arrow.down")
            }
            .disabled(kitchen.isImportingRecipe)
        }

        cookTonightSection

        Section("Saved recipes") {
            if kitchen.recipes.isEmpty {
                Text("No recipes yet.").foregroundStyle(.secondary)
            } else {
                ForEach(kitchen.recipes) { recipe in
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            editingRecipe = recipe
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(recipe.title).font(.headline)
                                Text("\(recipe.ingredients.count) ingredients · \(recipe.steps.count) steps")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)

                        let availability = kitchen.pantryAvailability(for: recipe)
                        let missing = availability.filter { !$0.1 }.map(\.0.name)
                        if !missing.isEmpty {
                            Text("Missing: \(missing.joined(separator: ", "))")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }

                        HStack {
                            Button("Cook") { Task { await kitchen.startCooking(recipe) } }
                                .buttonStyle(.borderedProminent)
                            Button("Shop missing") { Task { await kitchen.addMissingFromRecipe(recipe) } }
                        }
                        .font(.caption)
                    }
                    .padding(.vertical, 4)
                    .swipeActions {
                        Button(role: .destructive) {
                            Task { await kitchen.deleteRecipe(recipe) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var cookTonightSection: some View {
        let suggestions = kitchen.recipeSuggestions(limit: 3)
        if suggestions.contains(where: { $0.have > 0 }) {
            Section("Cook tonight") {
                ForEach(suggestions) { match in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(match.recipe.title)
                                .font(.headline)
                            Spacer()
                            Text("\(match.have)/\(match.total) on hand")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(match.missing == 0 ? .green : Self.terracotta)
                        }
                        ProgressView(value: match.fraction)
                            .tint(match.missing == 0 ? .green : Self.terracotta)
                        HStack {
                            Button("Cook") { Task { await kitchen.startCooking(match.recipe) } }
                                .buttonStyle(.borderedProminent)
                            if match.missing > 0 {
                                Button("Shop missing") {
                                    Task { await kitchen.addMissingFromRecipe(match.recipe) }
                                }
                            }
                        }
                        .font(.caption)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Shopping

    @ViewBuilder
    private var shoppingSections: some View {
        Section {
            Button { showNewShopping = true } label: {
                Label("Add item", systemImage: "plus")
            }
            Button {
                Task { await kitchen.addPantryLowsToShopping() }
            } label: {
                Label("Add pantry lows", systemImage: "exclamationmark.circle")
            }
            Button {
                Task { await kitchen.addMissingFromMealPlan() }
            } label: {
                Label("Build from this week's meals", systemImage: "calendar.badge.plus")
            }
            ShareLink(item: kitchen.shoppingShareText) {
                Label("Share list", systemImage: "square.and.arrow.up")
            }
            Button("Clear checked", role: .destructive) {
                Task { await kitchen.clearCheckedShopping() }
            }
        }
        .alert("Add shopping item", isPresented: $showNewShopping) {
            TextField("Name", text: $newShoppingName)
            Button("Add") {
                let name = newShoppingName.trimmingCharacters(in: .whitespacesAndNewlines)
                newShoppingName = ""
                guard !name.isEmpty else { return }
                Task { await kitchen.saveShoppingItem(ShoppingListItem(name: name)) }
            }
            Button("Cancel", role: .cancel) { newShoppingName = "" }
        }

        if kitchen.shoppingItems.isEmpty {
            Section("List") {
                Text("List is empty.").foregroundStyle(.secondary)
            }
        } else {
            let groups = kitchen.shoppingGroupedByCategory
            ForEach(groups, id: \.category) { group in
                Section(groups.count == 1 && group.category == "Other" ? "List" : group.category) {
                    ForEach(group.items) { item in
                        shoppingRow(item)
                    }
                }
            }
        }
    }

    private func shoppingRow(_ item: ShoppingListItem) -> some View {
        Button {
            Task { await kitchen.toggleShopping(item) }
        } label: {
            HStack {
                Image(systemName: item.checked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.checked ? .green : .secondary)
                VStack(alignment: .leading) {
                    Text(item.name)
                        .strikethrough(item.checked)
                    if let q = item.quantity, !q.isEmpty {
                        Text(q).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .swipeActions {
            Button(role: .destructive) {
                Task { await kitchen.deleteShopping(item) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Meals

    @ViewBuilder
    private var mealSections: some View {
        let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        ForEach(0..<7, id: \.self) { day in
            Section(days[day]) {
                ForEach(MealSlotKind.allCases, id: \.self) { kind in
                    let slot = kitchen.mealPlan.slots.first { $0.dayOffset == day && $0.kind == kind }
                    Button {
                        mealEditor = MealSlotEditor(
                            dayOffset: day,
                            kind: kind,
                            recipeId: slot?.recipeId,
                            note: slot?.note ?? ""
                        )
                    } label: {
                        HStack {
                            Text(kind.rawValue.capitalized)
                            Spacer()
                            Text(slotLabel(slot))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private func slotLabel(_ slot: MealPlanSlot?) -> String {
        guard let slot, !slot.isEmpty else { return "—" }
        if let title = kitchen.recipeTitle(for: slot.recipeId) { return title }
        if let note = slot.note, !note.isEmpty { return note }
        return "—"
    }

    // MARK: - Profile

    @ViewBuilder
    private var profileSections: some View {
        nutritionDashboardSection

        Section("Nutrition profile") {
            TextField("Diet style", text: $kitchen.draftDietStyle)
            TextField("Allergens / avoid (comma-separated)", text: $kitchen.draftAllergensText)
            TextField("Goals (comma-separated)", text: $kitchen.draftGoalsText)
            TextField("Preferred cuisines", text: $kitchen.draftCuisinesText)
            TextField("Staples (comma-separated)", text: $kitchen.draftStaplesText, axis: .vertical)
                .lineLimit(3...6)
            TextField("Notes", text: $kitchen.draftNotes, axis: .vertical)
                .lineLimit(2...4)
            Button("Save profile") {
                Task { await kitchen.saveProfileFromDrafts() }
            }
        }

        Section("Daily targets (optional)") {
            targetField("Calories", text: $kitchen.draftCalorieTarget, unit: "kcal")
            targetField("Protein", text: $kitchen.draftProteinTarget, unit: "g")
            targetField("Carbs", text: $kitchen.draftCarbTarget, unit: "g")
            targetField("Fat", text: $kitchen.draftFatTarget, unit: "g")
        }

        Section("Log a meal") {
            TextField("What did you eat?", text: $mealLogDraft)
            Button("Log") {
                let text = mealLogDraft
                mealLogDraft = ""
                Task { await kitchen.logMeal(text) }
            }
            .disabled(kitchen.isScanning)
            Text("Opens a details sheet so you can assign breakfast/lunch/dinner/snack and macros. Or scan a meal photo under Scan.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if !kitchen.recentMeals.isEmpty {
            Section("Recent meals") {
                ForEach(kitchen.recentMeals.prefix(12)) { meal in
                    Button {
                        kitchen.editMeal(meal)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(meal.description)
                                Spacer(minLength: 8)
                                Text(meal.kind.displayName)
                                    .font(.caption)
                                    .foregroundStyle(Self.terracotta)
                            }
                            HStack(spacing: 8) {
                                Text(meal.at.formatted(date: .abbreviated, time: .shortened))
                                if let macros = Self.macroLabel(meal) {
                                    Text(macros).foregroundStyle(Self.terracotta)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var nutritionDashboardSection: some View {
        let macros = kitchen.todaysMacros
        let profile = kitchen.nutritionProfile
        Section("Today") {
            HStack(spacing: 8) {
                MacroRingView(title: "Cal", value: macros.calories, target: profile.calorieTarget, unit: "", color: Self.terracotta)
                MacroRingView(title: "Protein", value: macros.protein, target: profile.proteinTarget, unit: "g", color: .blue)
                MacroRingView(title: "Carbs", value: macros.carbs, target: profile.carbTarget, unit: "g", color: .green)
                MacroRingView(title: "Fat", value: macros.fat, target: profile.fatTarget, unit: "g", color: .orange)
            }
            .padding(.vertical, 4)
            if !kitchen.hasMacroData {
                Text("Use Scan → meal photo or ask Remy — she'll estimate calories and macros and they'll show up here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        let week = kitchen.weeklyCalories
        if week.contains(where: { $0.calories > 0 }) {
            Section("Calories · last 7 days") {
                Chart {
                    ForEach(week) { point in
                        BarMark(
                            x: .value("Day", point.day, unit: .day),
                            y: .value("Calories", point.calories)
                        )
                        .foregroundStyle(Self.terracotta.gradient)
                        .cornerRadius(3)
                    }
                    if let target = profileCalorieTarget {
                        RuleMark(y: .value("Target", target))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                            .foregroundStyle(.secondary)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisValueLabel(format: .dateTime.weekday(.narrow))
                    }
                }
                .frame(height: 130)
                .padding(.vertical, 4)
            }
        }
    }

    private var profileCalorieTarget: Double? { kitchen.nutritionProfile.calorieTarget }

    private func targetField(_ label: String, text: Binding<String>, unit: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("—", text: text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 90)
            Text(unit).foregroundStyle(.secondary)
        }
    }

    static func durationLabel(_ seconds: Int) -> String {
        if seconds % 60 == 0 { return "\(seconds / 60) min" }
        if seconds < 60 { return "\(seconds)s" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private static func macroLabel(_ meal: MealLogEntry) -> String? {
        var parts: [String] = []
        if let c = meal.calories, c > 0 { parts.append("\(Int(c)) kcal") }
        if let p = meal.proteinGrams, p > 0 { parts.append("\(Int(p))P") }
        if let cb = meal.carbsGrams, cb > 0 { parts.append("\(Int(cb))C") }
        if let f = meal.fatGrams, f > 0 { parts.append("\(Int(f))F") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Rows / sheets

private struct MacroRingView: View {
    let title: String
    let value: Double
    let target: Double?
    let unit: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(color.opacity(0.2), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(value))")
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            .frame(width: 56, height: 56)
            Text(title)
                .font(.caption2.weight(.semibold))
            Text(target.map { "of \(Int($0))\(unit)" } ?? "\(unit.isEmpty ? "kcal" : unit)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    private var fraction: CGFloat {
        guard let target, target > 0 else { return value > 0 ? 1 : 0 }
        return min(1, CGFloat(value / target))
    }
}

private struct PantryRow: View {
    let item: PantryItem

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                HStack(spacing: 8) {
                    if let q = item.quantity, !q.isEmpty {
                        Text(q).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(item.category.rawValue).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if item.stockLevel != .ok {
                Text(item.stockLevel.rawValue.uppercased())
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(item.stockLevel == .out ? Color.red.opacity(0.15) : Color.orange.opacity(0.15))
                    .foregroundStyle(item.stockLevel == .out ? .red : .orange)
                    .clipShape(Capsule())
            }
            if let exp = item.expiresAt, exp < Date().addingTimeInterval(3 * 24 * 3600) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        }
    }
}

private struct ScanItemRow: View {
    let item: FridgeScanDetectedItem

    var body: some View {
        HStack {
            Text(item.name)
            Spacer()
            if let q = item.quantity { Text(q).foregroundStyle(.secondary) }
            Text(item.stockLevel.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct PantryEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var item: PantryItem
    var onSave: (PantryItem) -> Void

    init(item: PantryItem, onSave: @escaping (PantryItem) -> Void) {
        _item = State(initialValue: item)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $item.name)
                TextField("Quantity", text: Binding(
                    get: { item.quantity ?? "" },
                    set: { item.quantity = $0.isEmpty ? nil : $0 }
                ))
                TextField("Notes", text: Binding(
                    get: { item.notes ?? "" },
                    set: { item.notes = $0.isEmpty ? nil : $0 }
                ))
                Picker("Category", selection: $item.category) {
                    ForEach(PantryCategory.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Location", selection: $item.location) {
                    ForEach(PantryLocation.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Stock", selection: $item.stockLevel) {
                    ForEach(StockLevel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                DatePicker(
                    "Expires",
                    selection: Binding(
                        get: { item.expiresAt ?? Date().addingTimeInterval(7 * 24 * 3600) },
                        set: { item.expiresAt = $0 }
                    ),
                    displayedComponents: .date
                )
                Toggle("Has expiry", isOn: Binding(
                    get: { item.expiresAt != nil },
                    set: { item.expiresAt = $0 ? (item.expiresAt ?? Date().addingTimeInterval(7 * 24 * 3600)) : nil }
                ))
            }
            .navigationTitle(item.name.isEmpty ? "New item" : "Edit item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        onSave(item)
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct RecipeEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var servingsText: String
    @State private var ingredientsText: String
    @State private var stepsText: String
    @State private var tagsText: String
    @State private var sourceNote: String
    private let recipeId: UUID
    private let sourceURL: String?
    var onSave: (Recipe) -> Void

    init(recipe: Recipe, onSave: @escaping (Recipe) -> Void) {
        recipeId = recipe.id
        sourceURL = recipe.sourceURL
        _title = State(initialValue: recipe.title)
        _servingsText = State(initialValue: recipe.servings.map(String.init) ?? "")
        _ingredientsText = State(initialValue: recipe.ingredients.map { ing in
            if let q = ing.quantity, !q.isEmpty { return "\(ing.name) — \(q)" }
            return ing.name
        }.joined(separator: "\n"))
        _stepsText = State(initialValue: recipe.steps.joined(separator: "\n"))
        _tagsText = State(initialValue: recipe.tags.joined(separator: ", "))
        _sourceNote = State(initialValue: recipe.sourceNote ?? "")
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                TextField("Servings", text: $servingsText)
                    .keyboardType(.numberPad)
                TextField("Ingredients (one per line, optional — qty)", text: $ingredientsText, axis: .vertical)
                    .lineLimit(4...12)
                TextField("Steps (one per line)", text: $stepsText, axis: .vertical)
                    .lineLimit(4...16)
                TextField("Tags (comma-separated)", text: $tagsText)
                TextField("Source note", text: $sourceNote)
                if let sourceURL, !sourceURL.isEmpty {
                    Text(sourceURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(title.isEmpty ? "New recipe" : "Edit recipe")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let ingredients = ingredientsText.split(separator: "\n").compactMap { line -> RecipeIngredient? in
                            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return nil }
                            if let range = trimmed.range(of: " — ") ?? trimmed.range(of: " - ") {
                                let name = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                                let qty = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                                return RecipeIngredient(name: name, quantity: qty.isEmpty ? nil : qty)
                            }
                            return RecipeIngredient(name: trimmed)
                        }
                        let steps = stepsText.split(separator: "\n")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        let tags = tagsText.split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        let recipe = Recipe(
                            id: recipeId,
                            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                            servings: Int(servingsText),
                            ingredients: ingredients,
                            steps: steps,
                            tags: tags,
                            sourceNote: sourceNote.isEmpty ? nil : sourceNote,
                            sourceURL: sourceURL
                        )
                        guard !recipe.title.isEmpty else { return }
                        onSave(recipe)
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct RecipeImportSheet: View {
    @Binding var urlText: String
    @Binding var pasteText: String
    var isImporting: Bool
    var onImport: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("URL") {
                    TextField("https://…", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                }
                Section("Or paste recipe text") {
                    TextField("Ingredients and steps…", text: $pasteText, axis: .vertical)
                        .lineLimit(6...16)
                }
                Section {
                    Button {
                        onImport()
                    } label: {
                        if isImporting {
                            ProgressView()
                        } else {
                            Label("Import", systemImage: "square.and.arrow.down")
                        }
                    }
                    .disabled(isImporting
                              || (urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  && pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
            .navigationTitle("Import recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

private struct MealLogEditorSheet: View {
    var onCancel: () -> Void
    var onSave: (MealLogEditorState) -> Void
    var onLookup: (String?, String?) -> Void
    var onSelectHit: (FoodNutritionHit) -> Void
    var hits: [FoodNutritionHit]
    var isLookingUp: Bool

    @State private var description: String
    @State private var kind: MealLogKind
    @State private var caloriesText: String
    @State private var proteinText: String
    @State private var carbsText: String
    @State private var fatText: String
    @State private var lookupQuery: String
    @State private var barcodeText: String

    private let draft: MealLogEditorState

    init(
        draft: MealLogEditorState,
        hits: [FoodNutritionHit],
        isLookingUp: Bool,
        onCancel: @escaping () -> Void,
        onSave: @escaping (MealLogEditorState) -> Void,
        onLookup: @escaping (String?, String?) -> Void,
        onSelectHit: @escaping (FoodNutritionHit) -> Void
    ) {
        self.draft = draft
        self.hits = hits
        self.isLookingUp = isLookingUp
        self.onCancel = onCancel
        self.onSave = onSave
        self.onLookup = onLookup
        self.onSelectHit = onSelectHit
        _description = State(initialValue: draft.description)
        _kind = State(initialValue: draft.kind)
        _caloriesText = State(initialValue: Self.macroField(draft.calories))
        _proteinText = State(initialValue: Self.macroField(draft.proteinGrams))
        _carbsText = State(initialValue: Self.macroField(draft.carbsGrams))
        _fatText = State(initialValue: Self.macroField(draft.fatGrams))
        _lookupQuery = State(initialValue: draft.description)
        _barcodeText = State(initialValue: draft.barcode ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $kind) {
                        ForEach(MealLogKind.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }

                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                } header: {
                    Text(draft.isNew ? "Confirm meal" : "Edit meal")
                } footer: {
                    Text(draft.isNew
                         ? "Prefill is from the photo analysis — adjust anything before saving."
                         : "Changes update your diary and today’s macro totals.")
                }

                Section("Open Food Facts") {
                    TextField("Lookup name", text: $lookupQuery)
                    TextField("Barcode (UPC/EAN)", text: $barcodeText)
                        .keyboardType(.numberPad)
                    Button {
                        onLookup(
                            lookupQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : lookupQuery,
                            barcodeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : barcodeText
                        )
                    } label: {
                        if isLookingUp {
                            ProgressView()
                        } else {
                            Label("Lookup", systemImage: "magnifyingglass")
                        }
                    }
                    .disabled(isLookingUp)

                    ForEach(hits) { hit in
                        Button {
                            onSelectHit(hit)
                            description = hit.displayName
                            caloriesText = Self.macroField(hit.nutrition.calories)
                            proteinText = Self.macroField(hit.nutrition.proteinGrams)
                            carbsText = Self.macroField(hit.nutrition.carbsGrams)
                            fatText = Self.macroField(hit.nutrition.fatGrams)
                            barcodeText = hit.barcode ?? barcodeText
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hit.displayName).font(.subheadline.weight(.semibold))
                                HStack(spacing: 8) {
                                    if let c = hit.nutrition.calories {
                                        Text("\(Int(c)) kcal")
                                    }
                                    if let note = hit.servingNote {
                                        Text(note).foregroundStyle(.secondary)
                                    }
                                }
                                .font(.caption)
                            }
                        }
                    }
                }

                Section("Nutrition") {
                    macroField("Calories", text: $caloriesText, unit: "kcal")
                    macroField("Protein", text: $proteinText, unit: "g")
                    macroField("Carbs", text: $carbsText, unit: "g")
                    macroField("Fat", text: $fatText, unit: "g")
                }
            }
            .navigationTitle(draft.isNew ? "Log meal" : "Edit meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var saved = draft
                        saved.description = description
                        saved.kind = kind
                        saved.calories = Self.parseMacro(caloriesText)
                        saved.proteinGrams = Self.parseMacro(proteinText)
                        saved.carbsGrams = Self.parseMacro(carbsText)
                        saved.fatGrams = Self.parseMacro(fatText)
                        if saved.nutritionSource != .openFoodFacts {
                            saved.nutritionSource = .manual
                        }
                        let code = barcodeText.trimmingCharacters(in: .whitespacesAndNewlines)
                        saved.barcode = code.isEmpty ? saved.barcode : code
                        onSave(saved)
                    }
                    .disabled(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onChange(of: draft.calories) { _, newValue in
                caloriesText = Self.macroField(newValue)
            }
            .onChange(of: draft.proteinGrams) { _, newValue in
                proteinText = Self.macroField(newValue)
            }
            .onChange(of: draft.carbsGrams) { _, newValue in
                carbsText = Self.macroField(newValue)
            }
            .onChange(of: draft.fatGrams) { _, newValue in
                fatText = Self.macroField(newValue)
            }
            .onChange(of: draft.description) { _, newValue in
                description = newValue
            }
        }
    }

    private func macroField(_ label: String, text: Binding<String>, unit: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("—", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 100)
            Text(unit).foregroundStyle(.secondary)
        }
    }

    private static func macroField(_ value: Double?) -> String {
        guard let value else { return "" }
        if value.rounded() == value { return String(Int(value)) }
        return String(value)
    }

    private static func parseMacro(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed)
    }
}

private struct MealSlotEditor: Identifiable {
    var id: String { "\(dayOffset)-\(kind.rawValue)" }
    let dayOffset: Int
    let kind: MealSlotKind
    var recipeId: UUID?
    var note: String
}

private struct MealSlotSheet: View {
    @Environment(\.dismiss) private var dismiss
    let editor: MealSlotEditor
    let recipes: [Recipe]
    var onSave: (Int, MealSlotKind, UUID?, String?) -> Void
    var onClear: (Int, MealSlotKind) -> Void

    @State private var recipeId: UUID?
    @State private var note: String

    init(
        editor: MealSlotEditor,
        recipes: [Recipe],
        onSave: @escaping (Int, MealSlotKind, UUID?, String?) -> Void,
        onClear: @escaping (Int, MealSlotKind) -> Void
    ) {
        self.editor = editor
        self.recipes = recipes
        self.onSave = onSave
        self.onClear = onClear
        _recipeId = State(initialValue: editor.recipeId)
        _note = State(initialValue: editor.note)
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Recipe", selection: $recipeId) {
                    Text("None").tag(Optional<UUID>.none)
                    ForEach(recipes) { recipe in
                        Text(recipe.title).tag(Optional(recipe.id))
                    }
                }
                TextField("Or note", text: $note)
            }
            .navigationTitle("\(editor.kind.rawValue.capitalized)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Clear") {
                        onClear(editor.dayOffset, editor.kind)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(
                            editor.dayOffset,
                            editor.kind,
                            recipeId,
                            note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note
                        )
                        dismiss()
                    }
                }
            }
        }
    }
}
