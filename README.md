<h1 align="center">Alkaid</h1>

<p align="center">
  <strong>Pure Ruby file walking and parallel content search</strong>
</p>

<p align="center">
  <a href="https://rubygems.org/gems/alkaid"><img src="https://img.shields.io/gem/v/alkaid.svg?colorB=319e8c" alt="Gem Version"></a>
  <a href="https://rubygems.org/gems/alkaid"><img src="https://img.shields.io/gem/dt/alkaid.svg" alt="Downloads"></a>
  <img src="https://img.shields.io/badge/ruby-%3E%3D%203.1-ruby.svg" alt="Ruby Version">
  <a href="LICENSE.txt"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"></a>
</p>

<p align="center">
  <a href="#features">Features</a> ·
  <a href="#installation">Installation</a> ·
  <a href="#quick-start">Quick Start</a> ·
  <a href="#search-behavior">Search Behavior</a> ·
  <a href="#search-options">Search Options</a>
</p>

---

Alkaid is a pure Ruby file walker and parallel content search library. It
streams deterministic, byte-accurate matches without depending on an editor,
Git implementation, or fuzzy matcher.

## Features

- Literal and regular-expression content search
- Deterministic ordering across serial and parallel workers
- Byte-accurate offsets and ranges, including multiline matches
- Include/exclude globs, file-size and result limits, and whole-word matching
- Progress reporting and cancellation with worker cleanup
- Cycle-safe file walking with pluggable ignore rules

## Installation

```ruby
gem "alkaid"
```

Alkaid supports Ruby 3.1 and later.

## Quick Start

```ruby
require "alkaid"

search = Alkaid::Search.new(
  Dir.pwd,
  pattern: "TODO",
  include: ["**/*.rb"],
  workers: 4
)

search.run do |match|
  puts "#{match.path}:#{match.line_number}:#{match.byte_offset}"
end
```

## Search behavior

`byte_offset` is the match's zero-based offset in the file. `ranges` contains
zero-based byte ranges in `line`, which retains its original line ending.
For a match spanning lines, `line` contains the complete lines touched by the
match and `line_number` identifies the first one.
Results are ordered by relative path and byte offset even when worker processes
are enabled.

## Ignore rules

Pass any ignore object that implements `ignored?(path, directory:)`. Alkaid
does not parse ignore files and does not depend on a Git library:

```ruby
ignore = MyIgnoreMatcher.new
files = Alkaid::Walker.new(Dir.pwd, ignore: ignore).to_a
search = Alkaid::Search.new(Dir.pwd, pattern: /error/i, ignore: ignore)
```

## Search options

Literal and regular-expression searches support case folding, whole-word
matching, include/exclude globs, file-size limits, result limits, cancellation,
and optional symlink or hidden-file traversal. Binary and invalid UTF-8 files
are skipped.

```ruby
search.cancel
progress = search.progress
```

## Development

```sh
bundle install
bundle exec rake test
bundle exec rbs -I sig validate
BUDGET=1 bundle exec rake bench
gem build --strict alkaid.gemspec
```

Use `FILES=100000 BYTES=10000 bundle exec rake bench` to exercise the full
100,000-file, approximately 1 GB design workload.

## Contributing

Bug reports and pull requests are welcome at https://github.com/noxdea/alkaid.

## License

Alkaid is available under the [MIT License](LICENSE.txt).
