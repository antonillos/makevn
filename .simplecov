SimpleCov.start do
  root File.expand_path(__dir__)
  coverage_dir "target/crap/shell-coverage"
  track_files "{bin/*,libexec/**/*.sh,*.sh}"
  add_filter "/test/"
  add_filter "/target/"
end
