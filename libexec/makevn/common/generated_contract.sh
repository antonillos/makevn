#!/usr/bin/env bash
set -euo pipefail

makevn_detect_generated_contract_output_dirs() {
  local maven_base_path="$1"
  local pom_path=""
  local dirs_text=""
  local result=""

  while IFS= read -r pom_path; do
    [[ -f "${pom_path}" ]] || continue

    dirs_text="$(MAKEVN_MAVEN_BASE="${maven_base_path}" perl -e '
      my $base = $ENV{"MAKEVN_MAVEN_BASE"};
      my $pom_dir = $ARGV[0];
      $pom_dir =~ s{/[^/]+$}{};  # dirname
      my $module = $pom_dir;
      $module =~ s{^\Q$base\E/?}{};  # strip base prefix
      $module = "." unless length $module;

      open my $fh, "<", $ARGV[0] or die "Cannot open $ARGV[0]";
      my $xml = do { local $/; <$fh> };
      close $fh;

      my %seen;

      sub tag_value {
        my ($xml, $tag) = @_;
        return $1 if $xml =~ m{<$tag(?:\s[^>]*)?>\s*([^<]+?)\s*</$tag>}s;
        return "";
      }

      sub resolve_path {
        my ($path) = @_;
        $path =~ s/\$\{project\.build\.directory\}/target/g;
        $path =~ s/\$\{project\.basedir\}/./g;
        return $path;
      }

      sub is_under_target {
        my ($path) = @_;
        return $path =~ m{^target/} || $path =~ m{^\./target/} || $path eq "target";
      }

      sub has_unresolved_properties {
        my ($path) = @_;
        return $path =~ m/\$\{/;
      }

      sub emit {
        my ($path) = @_;
        my $resolved = resolve_path($path);
        return unless is_under_target($resolved);
        my $full = $module eq "." ? $resolved : "$module/$resolved";
        my $key = "$module:$resolved";
        return if $seen{$key};
        $seen{$key} = 1;
        print "$full\n";
      }

      sub has_unpack_goal {
        my ($plugin_xml) = @_;
        while ($plugin_xml =~ m{<execution>.*?</execution>}sg) {
          my $exec = $&;
          while ($exec =~ m{<goal>([^<]+)</goal>}g) {
            return 1 if $1 eq "unpack";
          }
        }
        return 0;
      }

      while ($xml =~ m{<plugin(?:\s[^>]*)?>.*?</plugin>}sg) {
        my $plugin = $&;
        my $group_id = tag_value($plugin, "groupId");
        my $artifact_id = tag_value($plugin, "artifactId");
        next unless $artifact_id;

        # avro-maven-plugin
        if ($artifact_id eq "avro-maven-plugin") {
          emit("target/avro");
          my $out = tag_value($plugin, "outputDirectory");
          if ($out) {
            emit($out);
          } else {
            emit("target/generated-sources/avro");
          }
          next;
        }

        # maven-dependency-plugin (unpack goal only)
        if ($artifact_id eq "maven-dependency-plugin" && has_unpack_goal($plugin)) {
          emit("target/dependency-maven-plugin-markers");
          while ($plugin =~ m{<artifactItem>.*?</artifactItem>}sg) {
            my $item = $&;
            my $out = tag_value($item, "outputDirectory");
            if ($out) {
              emit($out);
              emit("target/dependency-maven-plugin-markers");
            }
          }
          next;
        }

        # openapi-generator-maven-plugin
        if ($artifact_id eq "openapi-generator-maven-plugin") {
          my $out = tag_value($plugin, "output");
          if ($out) {
            emit($out);
          } else {
            emit("target/generated-sources/openapi");
          }
          next;
        }

        # protobuf-maven-plugin
        if ($artifact_id eq "protobuf-maven-plugin") {
          my $out = tag_value($plugin, "outputDirectory");
          if ($out) {
            emit($out);
          } else {
            emit("target/generated-sources/protobuf");
          }
          next;
        }
      }

      # Always add catch-all for this module if any plugin was matched
      my $catchall = $module eq "." ? "target/generated-sources" : "$module/target/generated-sources";
      print "$catchall\n" unless $seen{"$module:target/generated-sources"};
    ' -- "${pom_path}")"

    if [[ -n "${dirs_text}" ]]; then
      while IFS= read -r dir_entry; do
        result="$(printf '%s\n%s' "${result}" "${dir_entry}")"
      done <<< "${dirs_text}"
    fi
  done < <(
    if [[ -f "${maven_base_path}/pom.xml" ]]; then
      printf '%s\n' "${maven_base_path}/pom.xml"
    fi
    find "${maven_base_path}" \
      \( -path '*/target/*' -o -path '*/node_modules/*' -o -path "${maven_base_path}/pom.xml" \) -prune \
      -o -name pom.xml -type f -print 2>/dev/null | LC_ALL=C sort
  )

  if [[ -n "${result}" ]]; then
    printf '%s\n' "${result}"
  fi
}

makevn_clean_generated_contract_targets() {
  local repo_root="$1"
  local maven_base_path="$2"
  local dir=""
  local outside_target=""
  local warn_dirs=""

  while IFS= read -r dir; do
    [[ -n "${dir}" ]] || continue
    if [[ "${dir}" != target/* && "${dir}" != target ]]; then
      # Skip paths with unresolved Maven properties (the catch-all covers them)
      if [[ "${dir}" != *'${'* ]]; then
        warn_dirs="$(makevn_append_word "${warn_dirs}" "${dir}")"
      fi
      continue
    fi
    if [[ -d "${maven_base_path}/${dir}" ]]; then
      if makevn_frontend_owns_loader 2>/dev/null; then
        :
      else
        makevn_print_detail_line "clean generated-contract: ${dir}"
      fi
      rm -rf "${maven_base_path:?}/${dir}"
    fi
  done <<< "$(makevn_detect_generated_contract_output_dirs "${maven_base_path}")"

  if [[ -n "${warn_dirs}" ]]; then
    printf '%s\n' "$(makevn_warn "Warning: generated-contract output directories outside target/ are not cleaned automatically: ${warn_dirs}")" >&2
    printf '%s\n' "$(makevn_dim "Add them to MAKEVN_GENERATED_CONTRACT_CLEAN_DIRS in .makevn/config if needed.")" >&2
  fi
}

makevn_should_clean_generated_contract_targets() {
  local repo_root="$1"
  makevn_load_config "${repo_root}"
  if [[ "${MAKEVN_CLEAN_GENERATED_CONTRACT_TARGETS:-}" == "false" ]]; then
    return 1
  fi
  return 0
}

makevn_clean_generated_contract_if_needed() {
  local repo_root="$1"
  local maven_base_path_resolved=""

  makevn_should_clean_generated_contract_targets "${repo_root}" || return 0

  maven_base_path_resolved="$(makevn_detect_maven_base_path "${repo_root}" || true)"
  if [[ -z "${maven_base_path_resolved}" ]]; then
    return 0
  fi

  makevn_clean_generated_contract_targets "${repo_root}" "${maven_base_path_resolved}"
}
