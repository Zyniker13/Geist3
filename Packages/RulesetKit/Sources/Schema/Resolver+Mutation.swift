// Resolver+Mutation.swift — tree mutation for the resolver's patch engine
// (P2.6): the `Mutation` outcome type and the pointer-driven mutators.
// Declaration arrays are navigated by `byId` pairs; numeric segments are
// refused everywhere.

import Foundation

extension Resolver {
    // MARK: Tree mutation

    /// The outcome of one mutation attempt against the tree.
    enum Mutation {
        case mutated(JSON)
        case failed(ResolveError.Kind, String)
        var failureKind: ResolveError.Kind {
            if case .failed(let kind, _) = self { return kind }
            return .badPointer
        }
        var failureMessage: String? {
            if case .failed(_, let message) = self { return message }
            return nil
        }
    }

    /// The outcome of descending to a pointer's parent container.
    enum DescentOutcome {
        case ok(container: JSON, endedOnElement: Bool)
        case fail(Mutation)
    }

    /// Descend to the parent container of the pointer's final segment,
    /// consuming `byId`/id pairs as needed. Returns the container and
    /// whether the pointer ended exactly on an id pair (naming the element
    /// itself).
    static func descend(
        _ tree: JSON, segments: [String], pointer: Pointer
    ) -> DescentOutcome {
        var container = tree
        var index = 0
        var endedOnElement = false
        while index < segments.count - 1 {
            let segment = segments[index]
            switch container {
            case .object(let fields):
                guard let position = fields.firstIndex(where: { $0.key == segment }) else {
                    return .fail(.failed(.missingTarget, "no key \(segment) along \(pointer.normalized)"))
                }
                container = fields[position].value
                index += 1
            case .array:
                guard segment == "byId", index + 1 < segments.count else {
                    if segment.first?.isNumber == true {
                        return .fail(.failed(.numericIndex, "numeric index \(segment) is not allowed"))
                    }
                    return .fail(.failed(.badPointer, "cannot address an array element by \(segment)"))
                }
                let id = segments[index + 1]
                guard case .array(let items) = container else {
                    return .fail(.failed(.badPointer, "unreachable"))
                }
                guard
                    let position = items.firstIndex(where: {
                        $0.fields?.first(where: { $0.key == "id" })?.value == .string(id)
                    })
                else {
                    return .fail(.failed(.unknownId(id), "no element with id \(id) in \(pointer.normalized)"))
                }
                container = items[position]
                index += 2
                endedOnElement = (index == segments.count)
            default:
                return .fail(.failed(.badPointer, "\(pointer.normalized) descends into a scalar"))
            }
        }
        return .ok(container: container, endedOnElement: endedOnElement)
    }

    /// A single mutation request: the op and its payload.
    struct MutationOp {
        let op: String
        let value: JSON
    }

    /// A pointer ending exactly at an id pair names the array element
    /// itself, not a key inside it.
    static func mutateElement(_ tree: JSON, pointer: Pointer, request: MutationOp) -> Mutation {
        switch request.op {
        case "replace":
            return .mutated(rebuild(tree, path: pointer.segments, with: request.value))
        case "remove":
            return removeElement(
                tree, parentPath: Array(pointer.segments.dropLast(2)),
                id: pointer.segments.last ?? "", pointer: pointer)
        default:
            return .failed(
                .badPointer,
                "\(request.op): \(pointer.normalized) names an element; address a key inside it")
        }
    }

    /// The object-container branch of `mutate`: replace/add/append/remove
    /// the key `last` inside `fields`.
    static func mutateObject(
        tree: JSON, fields: [JSONField], request: MutationOp, last: String,
        parentPath: [String], pointer: Pointer
    ) -> Mutation {
        let position = fields.firstIndex(where: { $0.key == last })
        switch request.op {
        case "replace":
            guard let position else {
                return .failed(.missingTarget, "replace: no key \(last) at \(pointer.normalized)")
            }
            var newFields = fields
            newFields[position].value = request.value
            return .mutated(rebuild(tree, path: parentPath, with: .object(newFields)))
        case "add":
            if let position {
                // Adding into an existing array key inserts at the end.
                if case .array = fields[position].value {
                    return appendToArray(tree, path: parentPath + [last], value: request.value, pointer: pointer)
                }
                return .failed(.alreadyExists, "add: key \(last) already exists at \(pointer.normalized)")
            }
            var newFields = fields
            newFields.append(JSONField(key: last, value: request.value))
            return .mutated(rebuild(tree, path: parentPath, with: .object(newFields)))
        case "append":
            guard position != nil else {
                return .failed(.missingTarget, "append: no key \(last) at \(pointer.normalized)")
            }
            return appendToArray(tree, path: parentPath + [last], value: request.value, pointer: pointer)
        case "remove":
            guard let position else {
                return .failed(.missingTarget, "remove: no key \(last) at \(pointer.normalized)")
            }
            var newFields = fields
            newFields.remove(at: position)
            return .mutated(rebuild(tree, path: parentPath, with: .object(newFields)))
        default:
            return .failed(.badPointer, "unknown op \(request.op)")
        }
    }

    /// Apply `op` at `pointer`. Declaration arrays are navigated by `byId`
    /// pairs; numeric segments are refused everywhere.
    static func mutate(_ tree: JSON, pointer: Pointer, op: String, value: JSON) -> Mutation {
        let request = MutationOp(op: op, value: value)
        let segments = pointer.segments
        let descent = Self.descend(tree, segments: segments, pointer: pointer)
        guard case .ok(let container, let endedOnElement) = descent else {
            if case .fail(let failure) = descent { return failure }
            return .failed(.badPointer, "unreachable")
        }
        if endedOnElement {
            return mutateElement(tree, pointer: pointer, request: request)
        }

        var parentPath = segments
        let last = parentPath.removeLast()
        switch container {
        case .object(let fields):
            return mutateObject(
                tree: tree, fields: fields, request: request, last: last,
                parentPath: parentPath, pointer: pointer)
        case .array:
            guard last == "byId" else {
                if last.first?.isNumber == true {
                    return .failed(.numericIndex, "numeric index \(last) is not allowed")
                }
                return .failed(.badPointer, "cannot address an array element by \(last)")
            }
            // A trailing `byId` without an id targets the array itself.
            return .failed(.badPointer, "\(pointer.normalized) ends at byId")
        default:
            return .failed(.badPointer, "\(pointer.normalized) targets a scalar")
        }
    }

    /// Remove the element with `id` from the array at `parentPath`, rebuilding
    /// the parent chain unchanged.
    static func removeElement(
        _ tree: JSON, parentPath: [String], id: String, pointer: Pointer
    ) -> Mutation {
        var container = tree
        var index = 0
        while index < parentPath.count {
            let segment = parentPath[index]
            switch container {
            case .object(let fields):
                guard let position = fields.firstIndex(where: { $0.key == segment }) else {
                    return .failed(.missingTarget, "no key \(segment) along \(pointer.normalized)")
                }
                container = fields[position].value
                index += 1
            case .array:
                guard segment == "byId", index + 1 < parentPath.count else {
                    return .failed(.badPointer, "cannot address an array element by \(segment)")
                }
                let inner = parentPath[index + 1]
                guard case .array(let items) = container,
                    let position = items.firstIndex(where: {
                        $0.fields?.first(where: { $0.key == "id" })?.value == .string(inner)
                    })
                else {
                    return .failed(.unknownId(inner), "no element with id \(inner) in \(pointer.normalized)")
                }
                container = items[position]
                index += 2
            default:
                return .failed(.badPointer, "\(pointer.normalized) descends into a scalar")
            }
        }
        guard case .array(var items) = container,
            let position = items.firstIndex(where: {
                $0.fields?.first(where: { $0.key == "id" })?.value == .string(id)
            })
        else {
            return .failed(.unknownId(id), "no element with id \(id) in \(pointer.normalized)")
        }
        items.remove(at: position)
        return .mutated(rebuild(tree, path: parentPath, with: .array(items)))
    }

    /// Append `value` to the array at `path` (an effect list or a declaration
    /// array); the parent chain is rebuilt unchanged.
    static func appendToArray(_ tree: JSON, path: [String], value: JSON, pointer: Pointer) -> Mutation {
        var segments = path
        let last = segments.removeLast()
        var container = tree
        var index = 0
        while index < segments.count {
            let segment = segments[index]
            switch container {
            case .object(let fields):
                guard let position = fields.firstIndex(where: { $0.key == segment }) else {
                    return .failed(.missingTarget, "no key \(segment) along \(pointer.normalized)")
                }
                container = fields[position].value
                index += 1
            case .array:
                guard segment == "byId", index + 1 < segments.count else {
                    return .failed(.badPointer, "cannot address an array element by \(segment)")
                }
                let id = segments[index + 1]
                guard case .array(let items) = container,
                    let position = items.firstIndex(where: {
                        $0.fields?.first(where: { $0.key == "id" })?.value == .string(id)
                    })
                else {
                    return .failed(.unknownId(id), "no element with id \(id) in \(pointer.normalized)")
                }
                container = items[position]
                index += 2
            default:
                return .failed(.badPointer, "\(pointer.normalized) descends into a scalar")
            }
        }
        guard case .object(let fields) = container,
            let arrayField = fields.first(where: { $0.key == last }),
            var items = arrayField.value.arrayValue
        else {
            return .failed(.notAnArray, "append: \(last) at \(pointer.normalized) is not an array")
        }
        items.append(value)
        return .mutated(rebuild(tree, path: segments + [last], with: .array(items)))
    }

    /// Replace the value reached by `path` with `replacement`, returning a new
    /// tree. `path` is in raw segment form: `byId`/id pairs are consumed here
    /// exactly as the descent in `mutate` consumed them.
    static func rebuild(_ tree: JSON, path: [String], with replacement: JSON) -> JSON {
        guard let head = path.first else { return replacement }
        var remaining = path
        remaining.removeFirst()
        switch tree {
        case .object(var fields):
            guard let position = fields.firstIndex(where: { $0.key == head }) else { return tree }
            fields[position].value = rebuild(fields[position].value, path: remaining, with: replacement)
            return .object(fields)
        case .array(var items):
            // A `byId` marker plus the id that follows it address one element.
            guard head == "byId", !remaining.isEmpty else { return tree }
            let id = remaining.removeFirst()
            guard
                let position = items.firstIndex(where: {
                    $0.fields?.first(where: { $0.key == "id" })?.value == .string(id)
                })
            else { return tree }
            items[position] = rebuild(items[position], path: remaining, with: replacement)
            return .array(items)
        default:
            return tree
        }
    }
}
