#!/usr/bin/env node

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const repoRoot = join(here, '..', '..')
const schema = JSON.parse(readFileSync(join(here, 'documents.json'), 'utf8'))

const HEADER = () => ''

function swiftType(t) {
  if (t.startsWith('list:')) return `[${swiftType(t.slice(5))}]`
  return { string: 'String', int: 'Int', double: 'Double', bool: 'Bool' }[t] ?? t
}

function emitSwift() {
  let out = HEADER('swift')
  out += 'import Foundation\n'
  for (const [name, def] of Object.entries(schema.types)) {
    out += '\n'
    if (def.kind === 'enum') {
      out += `public enum ${name}: String, Codable, Sendable, CaseIterable, Equatable {\n`

      const swiftKeywords = new Set(['in', 'repeat', 'default', 'for', 'if', 'else', 'case', 'return', 'true', 'false', 'nil', 'self', 'static', 'class', 'operator', 'func', 'let', 'var', 'where', 'do', 'catch', 'break', 'continue'])
      for (const c of def.cases) out += `    case ${swiftKeywords.has(c) ? '`' + c + '`' : c}\n`
      if (def.legacyAliases) {
        out += '\n'
        out += '    public init(from decoder: Decoder) throws {\n'
        out += '        let raw = try decoder.singleValueContainer().decode(String.self)\n'
        out += '        switch raw {\n'
        for (const [legacy, current] of Object.entries(def.legacyAliases)) {
          out += `        case "${legacy}": self = .${current}\n`
        }
        out += '        default:\n'
        out += '            guard let value = Self(rawValue: raw) else {\n'
        out += '                throw DecodingError.dataCorrupted(DecodingError.Context(\n'
        out += '                    codingPath: decoder.codingPath,\n'
        out += `                    debugDescription: "Unknown ${name} value: \\(raw)"\n`
        out += '                ))\n'
        out += '            }\n'
        out += '            self = value\n'
        out += '        }\n'
        out += '    }\n'
      }
      out += '}\n'
    } else if (def.kind === 'record') {
      const hasId = def.fields.some((f) => f.name === 'id')
      const conformances = ['Codable', 'Sendable', 'Equatable', ...(hasId ? ['Identifiable'] : [])]
      out += `public struct ${name}: ${conformances.join(', ')} {\n`
      for (const f of def.fields) {
        out += `    public var ${f.name}: ${swiftType(f.type)}${f.optional ? '?' : ''}\n`
      }
      out += '\n'
      const params = def.fields
        .map((f) => `${f.name}: ${swiftType(f.type)}${f.optional ? '? = nil' : ''}`)
        .join(', ')
      out += `    public init(${params}) {\n`
      for (const f of def.fields) out += `        self.${f.name} = ${f.name}\n`
      out += '    }\n}\n'
    } else {
      throw new Error(`Unknown kind '${def.kind}' for type '${name}'`)
    }
  }
  return out
}


function jsonSchemaType(t) {
  if (t.startsWith('list:')) return { type: 'array', items: jsonSchemaType(t.slice(5)) }
  const prim = {
    string: { type: 'string' },
    int: { type: 'integer' },
    double: { type: 'number' },
    bool: { type: 'boolean' },
  }[t]
  return prim ?? { $ref: `#/components/schemas/${t}` }
}

function emitOpenAPISchemas() {
  const schemas = {}
  for (const [name, def] of Object.entries(schema.types)) {
    if (def.kind === 'enum') {
      schemas[name] = {
        type: 'string',
        enum: def.cases,
      }
    } else {
      const properties = {}
      const required = []
      for (const f of def.fields) {
        properties[f.name] = jsonSchemaType(f.type)
        if (!f.optional) required.push(f.name)
      }
      schemas[name] = {
        type: 'object',
        properties,
        ...(required.length ? { required } : {}),
      }
    }
  }
  return JSON.stringify({ schemaVersion: schema.schemaVersion, schemas }, null, 2) + '\n'
}

const targets = [
  {
    path: join(repoRoot, 'apps/mac/Packages/PresenterCore/Sources/PresenterCore/Generated/Models.swift'),
    content: emitSwift(),
  },
  {
    path: join(repoRoot, 'apps/mac/Packages/LocalAPI/Sources/LocalAPI/Resources/document-schemas.json'),
    content: emitOpenAPISchemas(),
  },
]

for (const t of targets) {
  mkdirSync(dirname(t.path), { recursive: true })
  writeFileSync(t.path, t.content)
  console.log(`wrote ${t.path.replace(repoRoot + '/', '')}`)
}
