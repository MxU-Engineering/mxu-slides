import Foundation

public enum OpenAPIDocument {
    public static let apiVersion = "1.0"

    public static func compose(routes: [APIRoute], schemaVersion: Int) -> JSONValue {
        var paths: [String: JSONValue] = [:]
        for route in routes {
            var operation: [String: JSONValue] = [
                "operationId": .string(route.operationId),
                "summary": .string(route.summary),
                "tags": .array([.string(route.tag)]),
                "security": .array([.object(["bearerToken": .array([])])]),
                "x-required-scope": .string(route.scope.rawValue),
                "responses": .object([
                    "200": .object([
                        "description": "Success",
                        "content": .object([
                            "application/json": .object(["schema": route.responseSchema])
                        ]),
                    ]),
                    "default": .object([
                        "description": "Error",
                        "content": .object([
                            "application/json": .object(["schema": .ref("Error")])
                        ]),
                    ]),
                ]),
            ]
            if let requestSchema = route.requestSchema {
                operation["requestBody"] = .object([
                    "required": .bool(false),
                    "content": .object([
                        "application/json": .object(["schema": requestSchema])
                    ]),
                ])
            }
            let parameters = pathParameters(in: route.path)
            if !parameters.isEmpty {
                operation["parameters"] = .array(parameters.map { name in
                    .object([
                        "name": .string(name), "in": "path", "required": true,
                        "schema": .object(["type": "string"]),
                    ])
                })
            }
            var pathItem: [String: JSONValue] = [:]
            if case .object(let existing) = paths[route.path] ?? .object([:]) {
                pathItem = existing
            }
            pathItem[route.method.lowercased()] = .object(operation)
            paths[route.path] = .object(pathItem)
        }

        var schemas = wireSchemas
        for (name, schema) in documentSchemas() {
            schemas[name] = schema
        }

        return .object([
            "openapi": "3.1.0",
            "info": .object([
                "title": "MxU Slides Local API",
                "version": .string(apiVersion),
                "description": .string(
                    "Local show-control and content API served by the MxU Slides Mac app. "
                        + "Three capability classes: view, control, and create/edit — scoped "
                        + "bearer tokens minted in Settings › API. Document payloads follow the "
                        + "app's schema (version \(schemaVersion))."
                ),
            ]),
            "paths": .object(paths),
            "components": .object([
                "securitySchemes": .object([
                    "bearerToken": .object([
                        "type": "http", "scheme": "bearer",
                        "description": "A token minted in Settings › API. Scopes nest: edit ⊃ control ⊃ view.",
                    ])
                ]),
                "schemas": .object(schemas),
            ]),
        ])
    }

    private static func pathParameters(in template: String) -> [String] {
        template.split(separator: "/").compactMap { segment in
            guard segment.hasPrefix("{"), segment.hasSuffix("}") else { return nil }
            return String(segment.dropFirst().dropLast())
        }
    }

    static func documentSchemas() -> [String: JSONValue] {
        guard let url = Bundle.module.url(forResource: "document-schemas", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              case .object(let root)? = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let schemas)? = root["schemas"]
        else { return [:] }
        var result: [String: JSONValue] = [:]
        for (name, schema) in schemas where !name.hasPrefix("MxU") {
            guard case .object(var object) = schema,
                  case .object(let properties)? = object["properties"]
            else {
                result[name] = schema
                continue
            }
            object["properties"] = .object(properties.filter { key, _ in
                !key.hasPrefix("mxu") && key != "excludedTimeHexIds"
            })
            result[name] = .object(object)
        }
        return result
    }

    public static func documentSchemaVersion() -> Int {
        guard let url = Bundle.module.url(forResource: "document-schemas", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              case .object(let root)? = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .integer(let version)? = root["schemaVersion"]
        else { return 0 }
        return version
    }

    static let wireSchemas: [String: JSONValue] = [
        "Error": obj([
            "status": int, "code": str, "message": str,
        ], required: ["status", "code", "message"]),
        "OK": obj(["ok": .object(["type": "boolean"])], required: ["ok"]),
        "Created": obj(["id": str], required: ["id"]),
        "LibrarySummary": obj([
            "counts": .object([
                "type": "object", "additionalProperties": .object(["type": "integer"]),
            ])
        ], required: ["counts"]),
        "LibraryEntry": obj([
            "id": str, "name": str, "kind": str, "folder": str,
            "updatedAt": .object(["type": "string", "format": "date-time"]),
        ], required: ["id", "name", "kind"]),
        "Document": .object([
            "type": "object",
            "description": "A schema document — see the per-kind component schemas (Presentation, Service, …).",
        ]),
        "ShowStatus": obj([
            "liveSlide": obj([
                "presentationId": str, "presentationName": str, "slideId": str,
                "slideIndex": int, "slideName": str, "serviceItemId": str, "occurrence": int,
                "stepIndex": int, "stepCount": int, "text": str, "slideCount": int,
            ], required: ["presentationId", "slideId"]),
            "nextSlideText": str,
            "service": obj([
                "id": str, "name": str,
            ], required: ["id", "name"]),
            "nextSlide": obj(["text": str, "presentationId": str, "slideId": str, "slideIndex": int]),
            "position": obj(["currentItemName": str, "nextItemName": str]),
            "mediaLayers": .object([
                "type": "object",
                "additionalProperties": obj([
                    "mediaId": str, "mediaName": str, "loops": .object(["type": "boolean"]),
                ], required: ["mediaId"]),
            ]),
            "overlays": .object([
                "type": "array",
                "items": obj(["id": str, "name": str, "layer": str], required: ["id", "name"]),
            ]),
            "alert": obj([
                "id": str, "message": str, "behavior": str, "target": str, "layer": str,
            ], required: ["id", "message", "behavior", "target"]),
            "currentServiceId": str,
        ], required: ["mediaLayers", "overlays"]),
        "TimerStatus": obj([
            "id": str, "name": str, "mode": str,
            "running": .object(["type": "boolean"]),
            "displaySeconds": int,
            "overrun": .object(["type": "boolean"]),
            "folderId": str, "folderName": str,
            "runningSince": .object(["type": "string", "format": "date-time"]),
            "bankedSeconds": num, "durationSeconds": num,
            "targetTime": .object(["type": "string", "format": "date-time"]),
            "armedAt": .object(["type": "string", "format": "date-time"]),
            "warnings": .object([
                "type": "array",
                "items": obj(["remainingSeconds": num, "colorHex": str], required: ["remainingSeconds", "colorHex"]),
            ]),
        ], required: ["id", "name", "mode", "running", "displaySeconds", "overrun"]),
        "SchedulerStatus": obj([
            "enabled": .object(["type": "boolean"]),
            "nextFire": obj([
                "triggerId": str, "name": str,
                "at": .object(["type": "string", "format": "date-time"]),
            ], required: ["triggerId", "name", "at"]),
            "triggers": .object([
                "type": "array",
                "items": obj([
                    "id": str, "name": str,
                    "enabled": .object(["type": "boolean"]),
                    "folderEnabled": .object(["type": "boolean"]),
                    "folderId": str, "folderName": str,
                    "nextFire": .object(["type": "string", "format": "date-time"]),
                    "lastFired": .object(["type": "string", "format": "date-time"]),
                    "archived": .object(["type": "boolean"]),
                ], required: ["id", "name", "enabled", "folderEnabled"]),
            ]),
        ], required: ["enabled", "triggers"]),
        "SchedulerEnableCommand": obj([
            "enabled": .object(["type": "boolean"])
        ], required: ["enabled"]),
        "VideoInputStatus": obj([
            "id": str, "name": str,
            "kind": .object([
                "type": "string", "enum": .array([.string("camera"), .string("ndi")]),
            ]),
            "sourceId": str, "audioInputId": str,
            "delayFrames": int,
        ], required: ["id", "name"]),
        "AudioInputStatus": obj([
            "id": str, "name": str, "deviceUid": str,
            "live": .object(["type": "boolean"]),
            "enabled": .object(["type": "boolean"]),
            "gain": num,
            "muted": .object(["type": "boolean"]),
            "mixId": str,
            "delayMs": int,
        ], required: ["id", "name", "live", "enabled", "gain", "muted"]),
        "AudioMixStatus": obj([
            "id": str, "name": str, "deviceUid": str,
            "channelOffset": int,
            "gain": num,
            "muted": .object(["type": "boolean"]),
            "outputIds": .object(["type": "array", "items": .object(["type": "string"])]),
        ], required: ["id", "name", "channelOffset", "gain", "muted"]),
        "MixerInputCommand": obj([
            "enabled": .object(["type": "boolean"]),
            "gain": num,
            "muted": .object(["type": "boolean"]),
            "delayMs": int,
        ]),
        "MIDIDeviceStatus": obj([
            "id": str, "name": str,
            "enabled": .object(["type": "boolean"]),
            "direction": .object([
                "type": "string", "enum": .array([.string("output"), .string("input"), .string("both")]),
            ]),
            "channel": int,
            "connected": .object(["type": "boolean"]),
            "destinationUid": int, "sourceUid": int,
        ], required: ["id", "name", "enabled", "direction", "connected"]),
        "MIDIDeviceEnableCommand": obj([
            "enabled": .object(["type": "boolean"])
        ], required: ["enabled"]),
        "AudioStatus": obj([
            "buses": .object([
                "type": "array",
                "items": obj([
                    "playlistId": str, "audioItemId": str, "trackName": str,
                    "playing": .object(["type": "boolean"]),
                    "position": num, "duration": num,
                ], required: ["playing"]),
            ])
        ], required: ["buses"]),
        "TransportRow": obj([
            "mediaId": str, "name": str, "layer": str,
            "playing": .object(["type": "boolean"]),
            "looping": .object(["type": "boolean"]),
            "position": num, "duration": num,
        ], required: ["mediaId", "name", "layer", "playing", "looping", "position", "duration"]),
        "OutputsStatus": obj([
            "screens": .object([
                "type": "array",
                "items": obj([
                    "id": str, "name": str, "role": str,
                    "backed": .object(["type": "boolean"]),
                    "width": num, "height": num,
                    "outputs": .object([
                        "type": "array",
                        "items": obj([
                            "id": str, "name": str,
                            "x": num, "y": num, "width": num, "height": num,
                            "backing": str,
                            "adjusted": .object(["type": "boolean"]),
                        ], required: [
                            "id", "x", "y", "width", "height", "backing", "adjusted",
                        ]),
                    ]),
                    "activeMasks": .object(["type": "array", "items": str]),
                ], required: [
                    "id", "name", "role", "backed", "width", "height",
                    "outputs", "activeMasks",
                ]),
            ]),
            "presets": .object([
                "type": "array",
                "items": obj([
                    "id": str, "name": str, "active": .object(["type": "boolean"]),
                ], required: ["id", "name", "active"]),
            ]),
        ], required: ["screens", "presets"]),
        "FireSlideCommand": obj([
            "presentationId": str, "slideId": str, "slideIndex": int,
            "arrangementId": str, "serviceItemId": str, "occurrence": int,
        ]),
        "AdvanceCommand": obj(["steps": int, "settled": .object(["type": "boolean"])]),
        "ClearCommand": obj(["function": str, "layer": str]),
        "FireAlertCommand": obj([
            "presetId": str, "message": str,
            "tokens": .object([
                "type": "object", "additionalProperties": .object(["type": "string"]),
            ]),
            "behavior": str, "target": str, "themeId": str,
        ]),
        "AudioFireCommand": obj(["startAtEntryId": str]),
        "AudioStopCommand": obj(["playlistId": str, "audioItemId": str]),
        "AudioTransportCommand": obj(["action": str, "position": num], required: ["action"]),
        "MediaTransportCommand": obj(["action": str, "position": num], required: ["action"]),
        "AddServiceItemCommand": obj(["refId": str, "index": int], required: ["refId"]),
        "ServerInfo": obj([
            "name": str, "product": str, "apiVersion": str, "schemaVersion": int,
        ], required: ["name", "product", "apiVersion", "schemaVersion"]),
    ]

    private static let str = JSONValue.object(["type": "string"])
    private static let int = JSONValue.object(["type": "integer"])
    private static let num = JSONValue.object(["type": "number"])

    private static func obj(
        _ properties: [String: JSONValue], required: [String] = []
    ) -> JSONValue {
        var value: [String: JSONValue] = [
            "type": "object",
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            value["required"] = .array(required.map { .string($0) })
        }
        return .object(value)
    }
}

public enum AsyncAPIDocument {

    static let payloadSchemas: [APITopic: (name: String, isList: Bool)] = [
        .show: ("ShowStatus", false),
        .timers: ("TimerStatus", true),
        .audio: ("AudioStatus", false),
        .transport: ("TransportRow", true),
        .outputs: ("OutputsStatus", false),
        .library: ("LibrarySummary", false),
        .scheduler: ("SchedulerStatus", false),
    ]

    static func topicDescription(_ topic: APITopic) -> String {
        switch topic {
        case .show:
            return "Snapshot pushed when the live show changes: the live slide (with step counters — stepIndex = click groups consumed so far, stepCount = click groups on the slide; both absent when the slide has no animation steps), next-slide text, media layers, overlays. Same shape as GET /v1/status. POST /v1/show/advance consumes one click group per call and pushes a new snapshot; past the last click one more call plays the exit group (the cue stays live, stepIndex reaches stepCount), and the call after that moves slides."
        default:
            return "Snapshot pushed when \(topic.rawValue) state changes; same shape as its REST endpoint."
        }
    }

    public static func compose(schemaVersion: Int) -> JSONValue {
        var channels: [String: JSONValue] = [:]
        var messages: [String: JSONValue] = [:]
        for topic in APITopic.allCases {
            let messageName = "\(topic.rawValue)Event"
            channels[topic.rawValue] = .object([
                "description": .string(topicDescription(topic)),
                "subscribe": .object([
                    "message": .object(["$ref": .string("#/components/messages/\(messageName)")])
                ]),
            ])
            let data: JSONValue
            if let payload = payloadSchemas[topic], let schema = OpenAPIDocument.wireSchemas[payload.name] {
                data = payload.isList ? .object(["type": "array", "items": schema]) : schema
            } else {
                data = .object(["type": "object"])
            }
            messages[messageName] = .object([
                "name": .string(messageName),
                "payload": .object([
                    "type": "object",
                    "properties": .object([
                        "type": .object(["type": "string", "const": "event"]),
                        "topic": .object(["type": "string", "const": .string(topic.rawValue)]),
                        "data": data,
                    ]),
                ]),
            ])
        }
        return .object([
            "asyncapi": "2.6.0",
            "info": .object([
                "title": "MxU Slides Local API — WebSocket",
                "version": .string(OpenAPIDocument.apiVersion),
                "description": .string(
                    "Connect to /v1/ws?token=SECRET. Send {\"type\":\"subscribe\",\"topics\":[…]} "
                        + "to receive state pushes; send {\"type\":\"command\",\"id\":…,\"method\":…,"
                        + "\"path\":…,\"body\":…} to invoke any REST operation over the socket. "
                        + "Document schema version \(schemaVersion)."
                ),
            ]),
            "channels": .object(channels),
            "components": .object([
                "messages": .object(messages)
            ]),
        ])
    }
}
