# Cloud Foundry Java Buildpack
# Copyright 2013-2017 the original author or authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

$LOAD_PATH.unshift File.expand_path('../../lib', __FILE__)

require 'java_buildpack/logging/logger_factory'
require 'java_buildpack/repository/version_resolver'
require 'java_buildpack/util/configuration_utils'
require 'java_buildpack/util/cache/download_cache'
require 'java_buildpack/util/snake_case'
require 'monitor'
require 'rake/tasklib'
require 'rakelib/package'
require 'pathname'
require 'yaml'
require 'fileutils'
require 'uri'

module Package
  class ExportDependenciesTask < Rake::TaskLib
    def initialize
      desc 'export dependencies'
      task export_dependencies: [TASK_DEPS]

      JavaBuildpack::Logging::LoggerFactory.instance.setup "#{BUILD_DIR}/"
      @default_repository_root = default_repository_root
      @cache                   = cache
      @monitor                 = Monitor.new

      configurations = component_ids.map { |component_id| component_configuration(component_id) }.flatten
      initialize_export_tasks(load_indexes(configurations))

      multitask TASK_DEPS => [BUILD_DIR, STAGING_DIR]
    end

    private

    EXPORT_DIR = File.join(BUILD_DIR, 'export')

    TASK_DEPS = 'export_deps'.freeze

    ARCHITECTURE_PATTERN = /\{architecture\}/

    DEFAULT_REPOSITORY_ROOT_PATTERN = /\{default.repository.root\}/

    PLATFORM_PATTERN = /\{platform\}/

    private_constant :ARCHITECTURE_PATTERN, :DEFAULT_REPOSITORY_ROOT_PATTERN, :PLATFORM_PATTERN

    def base_uri
      URI(ENV['BASE_URI'])
    end

    def augment(raw, key, pattern, candidates, &block)
      if raw.respond_to? :at
        raw.map(&block)
      elsif raw[:uri] =~ pattern
        candidates.map do |candidate|
          dup       = raw.clone
          dup[key]  = candidate
          dup[:uri] = raw[:uri].gsub pattern, candidate

          dup
        end
      else
        raw
      end
    end

    def augment_architecture(raw)
      augment(raw, :architecture, ARCHITECTURE_PATTERN, ARCHITECTURES) { |r| augment_architecture r }
    end

    def augment_path(raw)
      if raw.respond_to? :at
        raw.map { |r| augment_path r }
      else
        raw[:uri] = "#{raw[:uri].chomp('/')}/index.yml"
        raw
      end
    end

    def augment_platform(raw)
      augment(raw, :platform, PLATFORM_PATTERN, PLATFORMS) { |r| augment_platform r }
    end

    def augment_repository_root(raw)
      augment(raw, :repository_root, DEFAULT_REPOSITORY_ROOT_PATTERN, [@default_repository_root]) do |r|
        augment_repository_root r
      end
    end

    def cache
      JavaBuildpack::Util::Cache::DownloadCache.new(Pathname.new("#{STAGING_DIR}/resources/cache")).freeze
    end

    def download_dependency_task(url, dest_path)
      task url do |t|
        @monitor.synchronize { rake_output_message "Exporting #{t.name}" }
        @cache.get(url) do |file|
          FileUtils.mkdir_p File.dirname(dest_path)
          FileUtils.cp(file.path, dest_path)
        end
      end
      url
    end

    def cache_task(uri)
      task uri do |t|
        @monitor.synchronize { rake_output_message "Caching #{t.name}" }
        cache.get(t.name) {}
      end

      uri
    end

    def component_ids
      configuration('components').values.flatten.map { |component| component.split('::').last.snake_case }
    end

    def configuration(id)
      JavaBuildpack::Util::ConfigurationUtils.load(id, false, false)
    end

    def configurations(component_id, configuration, sub_component_id = nil)
      configurations = []

      if repository_configuration?(configuration)
        configuration['component_id']     = component_id
        configuration['sub_component_id'] = sub_component_id if sub_component_id
        configurations << configuration
      else
        configuration.each { |k, v| configurations << configurations(component_id, v, k) if v.is_a? Hash }
      end

      configurations
    end

    def component_configuration(component_id)
      configurations(component_id, configuration(component_id))
    end

    def default_repository_root
      configuration('repository')['default_repository_root'].chomp('/')
    end

    def index_configuration(configuration)
      [configuration['repository_root']]
        .map { |r| { uri: r } }
        .map { |r| augment_repository_root r }
        .map { |r| augment_platform r }
        .map { |r| augment_architecture r }
        .map { |r| augment_path r }.flatten
    end

    def repository_configuration?(configuration)
      configuration['version'] && configuration['repository_root']
    end

    def load_indexes(configurations)
      indexes = {}

      configurations.each do |configuration|
        index_configuration(configuration).each do |index_configuration|
          multitask TASK_DEPS => [cache_task(index_configuration[:uri])]
          get_from_cache(configuration, index_configuration, indexes)
        end
      end

      indexes
    end

    def initialize_export_tasks(indexes)
      indexes.each do |id, index|
        component_dir = File.join(EXPORT_DIR, id)
        index.each do |_, url|
          dest_path = File.join(component_dir, URI(url).request_uri)
          multitask TASK_DEPS => [download_dependency_task(url, dest_path)]
        end
        multitask TASK_DEPS => [rewrite_index_task(index, component_dir)]
      end
    end

    def rewrite_index_task(index, dest_dir)
      path = File.join(dest_dir, 'index.yml')
      task path do |_t|
        body = index.each_with_object({}) do |(k, v), hash|
          url = URI(v).tap do |uri|
            uri.scheme = base_uri.scheme
            uri.host = base_uri.host
            uri.port = base_uri.port
            uri.path = File.join(base_uri.path, uri.path)
          end
          hash[k] = url.to_s
        end
        FileUtils.mkdir_p dest_dir
        IO.write(path, body.to_yaml)
      end
      path
    end

    def get_from_cache(configuration, index_configuration, uris)
      @cache.get(index_configuration[:uri]) do |f|
        index = YAML.safe_load f
        id = [configuration['component_id'], configuration['sub_component_id']].compact.join('/')
        uris[id] = index
      end
    end

    def update_configuration(config, version, sub_component)
      if sub_component.nil?
        config['version'] = version
      elsif config.key?(sub_component)
        config[sub_component]['version'] = version
      else
        config.values.each { |v| update_configuration(v, version, sub_component) if v.is_a? Hash }
      end
    end
  end
end
