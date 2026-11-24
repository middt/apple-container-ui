import Foundation

// Compose project groups: the containers of one `docker compose` / Vessel stack shown and
// controlled as a unit.
extension ContainerStore {

    /// Groups `items` by Compose project, keeping the order in which projects first appear.
    func containerGroups(in items: [ContainerItem]) -> [ContainerGroup] {
        var order: [String] = []
        var members: [String: [ContainerItem]] = [:]
        for item in items {
            guard let project = item.composeProject, !project.isEmpty else { continue }
            let key = "\(item.backend.rawValue)|\(project)"
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(item)
        }
        return order.compactMap { key in
            guard let containers = members[key], let first = containers.first, let project = first.composeProject else { return nil }
            return ContainerGroup(name: project, backend: first.backend, containers: containers)
        }
    }

    /// Groups among the containers that pass the current search / state filter (for the list).
    var filteredContainerGroups: [ContainerGroup] {
        containerGroups(in: filteredContainers)
    }

    /// Filtered containers that do not belong to any Compose project.
    var filteredStandaloneContainers: [ContainerItem] {
        filteredContainers.filter { ($0.composeProject ?? "").isEmpty }
    }

    /// The complete group (all members, regardless of the list filter).
    func group(id: String) -> ContainerGroup? {
        containerGroups(in: containers).first { $0.id == id }
    }

    var selectedGroup: ContainerGroup? {
        selectedGroupID.flatMap { group(id: $0) }
    }

    /// The Vessel stack a group was deployed from, if it is known to this app.
    func stack(for group: ContainerGroup) -> ComposeStackItem? {
        stacks.first { $0.name == group.name && $0.targetBackend == group.backend }
            ?? stacks.first { $0.name == group.name }
    }

    func selectContainer(_ id: String) {
        selectedGroupID = nil
        selectedContainerID = id
    }

    func selectGroup(_ id: String) {
        selectedGroupID = id
    }

    func toggleGroupCollapsed(_ id: String) {
        if collapsedGroupIDs.contains(id) {
            collapsedGroupIDs.remove(id)
        } else {
            collapsedGroupIDs.insert(id)
        }
    }

    private func setState(_ state: ContainerState, forMembers ids: Set<String>) {
        var working = containers
        for idx in working.indices where ids.contains(working[idx].id) {
            working[idx].state = state
        }
        containers = working
    }

    /// Members in start order: services a stack depends on first, when the stack is known.
    private func startOrder(for group: ContainerGroup) -> [ContainerItem] {
        guard let stack = stack(for: group) else { return group.containers }
        let serviceOrder = stack.services.map { $0.name }
        func rank(_ container: ContainerItem) -> Int {
            let service = container.labels["com.docker.compose.service"] ?? ""
            return serviceOrder.firstIndex(of: service) ?? serviceOrder.count
        }
        return group.containers.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map { $0.element }
    }

    // MARK: - Bulk actions

    /// Starts every member that is not running.
    @discardableResult
    func startGroup(_ groupID: String) -> Task<Void, Never> {
        guard let group = group(id: groupID) else { return Task {} }
        let targets = startOrder(for: group).filter { $0.state != .running }
        guard !targets.isEmpty else { return Task {} }
        setState(.starting, forMembers: Set(targets.map { $0.id }))

        return Task {
            await withBusyLabel(t("Starting \(group.name)…", "\(group.name) başlatılıyor…")) {
                if group.backend == .dockerEngine {
                    await perform(.dockerEngine, ["start"] + targets.map { $0.cliID })
                } else {
                    // `container start` takes one container at a time.
                    for target in targets {
                        await perform(.appleContainer, ["start", target.cliID])
                    }
                }
            }
            await settle()
        }
    }

    /// Stops every running member with a single command.
    @discardableResult
    func stopGroup(_ groupID: String) -> Task<Void, Never> {
        guard let group = group(id: groupID) else { return Task {} }
        let targets = startOrder(for: group).reversed().filter { $0.state == .running }
        guard !targets.isEmpty else { return Task {} }
        setState(.stopping, forMembers: Set(targets.map { $0.id }))

        return Task {
            await withBusyLabel(t("Stopping \(group.name)…", "\(group.name) durduruluyor…")) {
                _ = await perform(group.backend, ["stop"] + targets.map { $0.cliID }, timeout: 300)
            }
            await settle()
        }
    }

    /// Restarts every member (stopped members are started too).
    @discardableResult
    func restartGroup(_ groupID: String) -> Task<Void, Never> {
        guard let group = group(id: groupID) else { return Task {} }
        let ordered = startOrder(for: group)
        guard !ordered.isEmpty else { return Task {} }
        setState(.starting, forMembers: Set(ordered.map { $0.id }))

        return Task {
            await withBusyLabel(t("Restarting \(group.name)…", "\(group.name) yeniden başlatılıyor…")) {
                if group.backend == .dockerEngine {
                    await perform(.dockerEngine, ["restart"] + ordered.map { $0.cliID }, timeout: 300)
                } else {
                    let running = ordered.reversed().filter { $0.state == .running }
                    if !running.isEmpty {
                        await perform(.appleContainer, ["stop"] + running.map { $0.cliID }, timeout: 300)
                    }
                    for target in ordered {
                        await perform(.appleContainer, ["start", target.cliID])
                    }
                }
            }
            await settle()
        }
    }

    /// Removes the whole group: `docker compose down` for Docker projects, or a forced delete of
    /// the members (plus the stack's network, when the stack is known) on `apple/container`.
    /// Named volumes are kept on both engines.
    @discardableResult
    func deleteGroup(_ groupID: String) -> Task<Void, Never> {
        guard let group = group(id: groupID) else { return Task {} }
        let ids = Set(group.containers.map { $0.id })
        setState(.stopping, forMembers: ids)

        return Task {
            let succeeded = await withBusyLabel(t("Deleting \(group.name)…", "\(group.name) siliniyor…")) { () -> Bool in
                if group.backend == .dockerEngine {
                    return await perform(.dockerEngine, ["compose", "--project-name", group.name, "down"], timeout: 600).succeeded
                }
                let deleted = await perform(
                    .appleContainer,
                    ["delete", "--force"] + group.containers.map { $0.cliID },
                    timeout: 300
                ).succeeded
                if deleted, let stack = stack(for: group), !stack.networkName.isEmpty, stack.networkName != "default", !stack.networkIsExternal {
                    await perform(.appleContainer, ["network", "delete", stack.networkName], reportFailure: false)
                }
                return deleted
            }
            if succeeded {
                for id in ids { inspectJSONByContainerID[id] = nil }
                if selectedGroupID == groupID { selectedGroupID = nil }
            }
            await settle()
        }
    }
}
