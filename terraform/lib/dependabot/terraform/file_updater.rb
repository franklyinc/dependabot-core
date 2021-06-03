# frozen_string_literal: true

require "dependabot/file_updaters"
require "dependabot/file_updaters/base"
require "dependabot/errors"
require "dependabot/terraform/file_selector"
require "dependabot/shared_helpers"

module Dependabot
  module Terraform
    class FileUpdater < Dependabot::FileUpdaters::Base
      include FileSelector

      def self.updated_files_regex
        [/\.tf$/, /\.hcl$/]
      end

      def updated_dependency_files
        updated_files = []
        
        [*terraform_files, *terragrunt_files, *lock_file].each do |file|
          next unless file_changed?(file)
          
          updated_content = updated_terraform_file_content(file)
          raise "Content didn't change!" if updated_content == file.content

          updated_files << updated_file(file: file, content: updated_content)
        end
        updated_files.compact!

        raise "No files changed!" if updated_files.none?

        updated_files
      end
      
      private

      def updated_terraform_file_content(file)
        content = file.content.dup

        reqs = dependency.requirements.zip(dependency.previous_requirements).
               reject { |new_req, old_req| new_req == old_req }

        # Loop through each changed requirement and update the files and lockfile
        reqs.each do |new_req, old_req|
          raise "Bad req match" unless new_req[:file] == old_req[:file]
          next unless new_req.fetch(:file) == file.name

          case new_req[:source][:type]
          when "git"
            update_git_declaration(new_req, old_req, content, file.name)
          when "registry" 
            update_registry_declaration(new_req, old_req, content)
          when "provider"
            update_registry_declaration(new_req, old_req, content)
            update_lockfile_declaration(new_req, old_req, content)
          else
            raise "Don't know how to update a #{new_req[:source][:type]} "\
                  "declaration!"
          end
        end

        content
      end

      def update_git_declaration(new_req, old_req, updated_content, filename)
        url = old_req.fetch(:source)[:url].gsub(%r{^https://}, "")
        tag = old_req.fetch(:source)[:ref]
        url_regex = /#{Regexp.quote(url)}.*ref=#{Regexp.quote(tag)}/

        declaration_regex = git_declaration_regex(filename)

        updated_content.sub!(declaration_regex) do |regex_match|
          regex_match.sub(url_regex) do |url_match|
            url_match.sub(old_req[:source][:ref], new_req[:source][:ref])
          end
        end
      end

      def update_registry_declaration(new_req, old_req, updated_content)
        regex = new_req[:source][:type] == "provider" ? provider_declaration_regex : registry_declaration_regex
        updated_content.sub!(regex) do |regex_match|
          regex_match.sub(/^\s*version\s*=.*/) do |req_line_match|
            req_line_match.sub(old_req[:requirement], new_req[:requirement])
          end
        end
      end

      def update_lockfile_declaration(new_req, old_req, updated_content)
        return unless lock_file?

        provider_source = new_req[:source][:registry_hostname] + "/" + new_req[:source][:module_identifier]

        SharedHelpers.in_a_temporary_directory do
          debugger
          dependency_files.each do |file|
            IO.write(file.name, file.content)
          end
          system "terraform providers lock #{provider_source}"
          return updated_file(file: lock_file, content: IO.read(".terraform.lock.hcl"))
        end
      end

      def dependency
        # Terraform updates will only ever be updating a single dependency
        dependencies.first
      end

      def files_with_requirement
        filenames = dependency.requirements.map { |r| r[:file] }
        dependency_files.select { |file| filenames.include?(file.name) }
      end

      def check_required_files
        return if [*terraform_files, *terragrunt_files].any?

        raise "No Terraform configuration file!"
      end

      def provider_declaration_regex
        name = Regexp.escape(dependency.name)
        /
          ((source\s*=\s*["']#{name}["']|\s*#{name}\s*=\s*\{.*)
          (?:(?!^\}).)+)
        /mx
      end

      def registry_declaration_regex
        /
          (?<=\{)
          (?:(?!^\}).)*
          source\s*=\s*["']#{Regexp.escape(dependency.name)}["']
          (?:(?!^\}).)*
        /mx
      end

      def git_declaration_regex(filename)
        # For terragrunt dependencies there's not a lot we can base the
        # regex on. Just look for declarations within a `terraform` block
        return /terraform\s*\{(?:(?!^\}).)*/m if terragrunt_file?(filename)

        # For modules we can do better - filter for module blocks that use the
        # name of the dependency
        /
          module\s+["']#{Regexp.escape(dependency.name)}["']\s*\{
          (?:(?!^\}).)*
        /mx
      end

    end
  end
end

Dependabot::FileUpdaters.
  register("terraform", Dependabot::Terraform::FileUpdater)
