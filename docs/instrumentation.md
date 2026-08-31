# Instrumentation

Funicular exposes an experimental, vendor-neutral instrumentation API for
local profilers and tracing adapters. Core records data only when at least one
registered adapter accepts the event.

```ruby
Funicular::Instrumentation.register(:example, adapter)

Funicular::Instrumentation.instrument(
  "app.checkout", nil, { "app.item_count" => 3 }
) do
  checkout
end
```

Adapters are duck typed; every hook is optional:

| Hook | Signature | Contract |
| --- | --- | --- |
| filter | `enabled?(name) -> bool` | Select a span or event name. |
| start | `start(span, parent_state) -> state` | Return adapter-owned state. |
| finish | `finish(state, span) -> void` | Observe the completed span exactly once. |
| activate | `activate(state) -> token` | Activate callback context. |
| deactivate | `deactivate(token) -> void` | Restore the previous context. |
| event | `event(event) -> void` | Observe an instantaneous event. |
| HTTP | `inject_http_headers(state, headers, url) -> void` | Add propagation headers only. |
| lifecycle | `flush()`, `shutdown()` | Flush or close the adapter. |

`start` receives the parent adapter state and may return any opaque state.
Adapter exceptions are isolated; three consecutive callback failures disable
only that adapter for the process/page. A successful callback resets the count.

`with_span` restores context around callback-style asynchronous work. Browser
context is VM-local; SSR context is thread-local. Adapter callbacks run inside
`silence`, which prevents instrumentation recursion.

```ruby
span = Funicular::Instrumentation.start("app.request")
request do |response|
  Funicular::Instrumentation.with_span(span) { consume(response) }
  Funicular::Instrumentation.finish(span)
end
```

## Built-in schema v1

`Funicular::Instrumentation::SCHEMA_VERSION` is `1`. Adding an optional field
is backward-compatible within v1. Removing a field, changing its meaning, or
changing its type requires a schema-version increment. Adapters must ignore
unknown fields and reject or stop exporting unknown major schema versions.

Spans are `funicular.boot`, `funicular.navigation`,
`funicular.component.mount`, `funicular.component.hydrate`,
`funicular.component.update`, `funicular.component.render`,
`funicular.vdom.diff`, `funicular.dom.patch`, `funicular.events.rebind`,
`funicular.http.request`, and `funicular.ssr.render`. Events are
`funicular.hydration.fallback` and `funicular.error`.

The complete built-in attribute catalog is:

| Operation | Attributes |
| --- | --- |
| boot | `funicular.local_database.enabled`, `funicular.boot.result`, `funicular.durability` |
| navigation | `funicular.navigation.kind`, `funicular.component.class`, `funicular.route.matched`, `funicular.route.pattern` |
| component mount | `funicular.component.class`, `funicular.component.child_count` |
| component hydrate | `funicular.component.class`, `funicular.hydration.result` |
| component update | `funicular.component.class`, `funicular.update.reason`, `funicular.update.changed_key_count`, `funicular.diff.empty`, `funicular.patch.count` |
| component render | `funicular.component.class` |
| VDOM diff | `funicular.component.class`, `funicular.diff.empty`, `funicular.patch.count` |
| DOM patch | `funicular.component.class`, `funicular.patch.count`, `funicular.root.replaced` |
| event rebind | `funicular.component.class`, `funicular.events.phase`, `funicular.event_listener.count` |
| HTTP | `http.request.method`, `http.response.status_code`, `funicular.http.result` |
| SSR | `funicular.ssr.mode`, `funicular.component.class`, `funicular.route.matched` |
| hydration fallback | `error.type` |
| error event | `funicular.error.source`, `error.type` |

Hydration results are `reused`, `full_render_fallback`, and
`failed_then_remounted`. Rebind emits separate `cleanup` and `bind` spans in
`funicular.events.phase`; listener count appears only on a successful bind.

Attribute keys must be strings. Values are limited to strings, integers,
floats, booleans, and `nil`. Built-in instrumentation never records state,
props, form values, raw URLs, query strings, HTTP bodies, cookies, tokens,
session identifiers, SQL, Cable payloads, DOM text, or error messages. Route
attributes use declared route patterns only.

HTTP adapters may add propagation headers through `inject_http_headers`.
Existing headers win case-insensitively, and the raw URL is supplied only for
the adapter's origin allowlist decision; it is not attached to the span.

With no matching adapter, Funicular skips clock reads, span/event allocation,
attribute hashes in framework hot paths, and patch-count traversal.

Run `bundle exec ruby benchmark/instrumentation.rb` to compare the no-adapter
and no-op-adapter update boundary. Run `bundle exec rake test:pico` after
installing `jsdom` to exercise the contract under the vendored PicoRuby runtime.
