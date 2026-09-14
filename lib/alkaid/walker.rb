# frozen_string_literal: true

require "set"

module Alkaid
  class Walker
    include Enumerable

    attr_reader :root

    def initialize(root, ignore: nil, follow_symlinks: false, hidden: false, max_depth: nil)
      @root = File.realpath(root)
      raise ArgumentError, "root must be a directory" unless File.directory?(@root)
      raise ArgumentError, "ignore must respond to ignored?" if ignore && !ignore.respond_to?(:ignored?)
      unless [follow_symlinks, hidden].all? { |value| value == true || value == false }
        raise ArgumentError, "traversal flags must be boolean"
      end
      unless max_depth.nil? || (max_depth.is_a?(Integer) && max_depth >= 0)
        raise ArgumentError, "max_depth must be nonnegative"
      end

      @ignore = ignore
      @follow_symlinks = follow_symlinks
      @hidden = hidden
      @max_depth = max_depth
    end

    def each(&block)
      return enum_for(__method__) unless block

      walk("", Set.new, &block)
      self
    end

    private

    def walk(directory, visited, &block)
      absolute_directory = absolute(directory)
      stat = File.stat(absolute_directory)
      return unless visited.add?([stat.dev, stat.ino])

      Dir.children(absolute_directory).sort.each do |name|
        next if name == ".git" || (!@hidden && name.start_with?("."))

        relative = directory.empty? ? name : File.join(directory, name)
        depth = relative.count("/\\") + 1
        next if @max_depth && depth > @max_depth

        visit(relative, depth, visited, &block)
      rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
        next
      end
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
      nil
    end

    def visit(relative, depth, visited, &block)
      path = absolute(relative)
      entry = File.lstat(path)
      if entry.symlink?
        return unless @follow_symlinks
        return unless inside_root?(File.realpath(path))

        entry = File.stat(path)
      end

      normalized = relative.tr("\\", "/")
      return if @ignore&.ignored?(normalized, directory: entry.directory?)

      if entry.directory?
        walk(relative, visited, &block) unless @max_depth && depth >= @max_depth
      elsif entry.file?
        yield normalized
      end
    end

    def absolute(relative) = relative.empty? ? root : File.join(root, relative)

    def inside_root?(path)
      path == root || path.start_with?(root.end_with?(File::SEPARATOR) ? root : root + File::SEPARATOR)
    end
  end
end
