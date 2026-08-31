# Funicular plugins

Add a plugin gem to the `:funicular` Bundler group:

```ruby
group :funicular do
  gem "my-plugin"
end
```

Use this layout for new plugins:

```text
my-plugin/
  mrblib/
    my_plugin.rb
  lib/
    my_plugin/
      railtie.rb
  assets/
    my_plugin.css
    my_plugin.js
```

When `mrblib/` exists, only its Ruby files are compiled into `app.mrb`;
`lib/` remains available to Rails. Plugins without `mrblib/` keep the legacy
behavior of compiling `lib/**/*.rb`. An existing but empty selected source
directory is an error.

Only top-level `assets/*.css` and `assets/*.js` files are served. Each type is
loaded in filename order, and plugins retain Bundler dependency order. Duplicate
logical asset paths are rejected.

Place plugin tags before the PicoRuby bootstrap so JavaScript bridges are ready
before the application starts:

```erb
<%= funicular_plugin_include_tags %>
<%= picoruby_include_tag defer: true %>
```

`bin/rails funicular:compile` copies plugin assets into the Rails build directory.
It also runs before `assets:precompile` in production.
