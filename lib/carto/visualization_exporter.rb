# encoding: utf-8

require_relative 'file_system/sanitize'

module Carto
  class DataExporter
    def initialize(http_client = Carto::Http::Client.get('data_exporter', log_requests: true))
      @http_client = http_client
    end

    # Returns the file
    def export_table(user_table, folder, format, is_remote)
      table_name = user_table.name

      query = %{select * from "#{table_name}"}
      url = sql_api_query_url(query, table_name, user_table.user, privacy(user_table), format)
      exported_file = "#{folder}/#{table_name}.#{format}"

      @http_client.get_file(url, exported_file, ssl_verifypeer: false, ssl_verifyhost: 0)

      # Hack for Samples 2.0 - Save As
      if(format == 'gpkg')
        # Verify if the data is remote or if it is local
        if(is_remote)
          Carto::GpkgCartoMetadataUtil.open( geopkg_file: exported_file ) do |md|
            md.metadata = { 
              vendor: 'carto',
              data: {
                source: {
                  type: 'fdw',
                  configuration: {
                    parent_table: table_name
                  }
                }
              }
            }.with_indifferent_access
            
            # Clear the data
            md.clear_table(table_name: table_name)
          end
          # Rename the file to .carto.gpkg to designate it has metadata
          # We do not immediately write to .carto.gpkg because the SQL api
          # does not honor .carto.gpkg format at this time
          
          File.rename(exported_file, "#{folder}/#{table_name}.carto.gpkg")
        end
      end
    end

    def export_visualization_tables(visualization, user, dir, format, user_tables_ids: nil)
      # Get all synchronizations
      synchronizations = visualization.related_canonical_visualizations.
        map { |v| v.synchronization }.
        select {|s| !s.nil? }
      
      # Get all tables
      #tables = visualization.
      #  related_tables_readable_by(user).
      #  select { |ut| user_tables_ids.nil? || user_tables_ids.include?(ut.id) }.
      tables = visualization.
        related_tables.
        select { |ut| user_tables_ids.nil? || user_tables_ids.include?(ut.id) }.
        map do |ut| 
          # We will do inefficient array search for now since the array length should be 
          #    no longer than 8 (total number of allowed layers).  Plus this logic
          #    will change from the hack for Sample 2.0 Save As to full solution 
          #    in the future
          
          # Find table in synchronizations
          is_remote = false
          for s in synchronizations
            if(ut.name == s.name)
              is_remote = true if s.service_name == 'connector'
            end
          end

          # Always export remote datasets and public.
          # Anything else should be excluded.
          if is_remote || ut.public?
              export_table(ut, dir, format, is_remote)
          end
        end
    end

    private

    def sql_api_query_url(query, filename, user, privacy, format)
      CartoDB::SQLApi.with_user(user, privacy).url(query, format, filename)
    end

    def privacy(user_table)
      user_table.private? ? 'private' : 'public'
    end
  end

  module ExporterConfig
    DEFAULT_EXPORTER_TMP_FOLDER = '/tmp/exporter'.freeze

    def exporter_config
      (Cartodb.config[:exporter] || {}).deep_symbolize_keys
    end

    def exporter_folder
      ensure_folder(exporter_config[:exporter_temporal_folder] || DEFAULT_EXPORTER_TMP_FOLDER)
    end

    def export_dir(visualization, base_dir: exporter_folder)
      ensure_folder("#{base_dir}/#{visualization.id}_#{String.random(10).downcase}")
    end

    # Example `parent_dir`: `export_dir(visualization, base_dir: base_dir)`
    def tmp_dir(visualization, parent_dir:)
      ensure_folder("#{parent_dir}/#{visualization.id}")
    end

    def ensure_folder(folder)
      FileUtils.mkdir_p(folder) unless Dir.exists?(folder)
      folder
    end

    def ensure_clean_folder(folder)
      FileUtils.remove_dir(folder) if Dir.exists?(folder)
      ensure_folder(folder)
    end
  end

  module VisualizationExporter
    include ExporterConfig

    DEFAULT_EXPORT_FORMAT = 'gpkg'.freeze
    EXPORT_EXTENSION = '.carto.json'.freeze
    CARTO_EXTENSION = '.carto'.freeze

    VISUALIZATION_EXTENSIONS = [Carto::VisualizationExporter::EXPORT_EXTENSION].freeze

    def self.has_visualization_extension?(filename)
      VISUALIZATION_EXTENSIONS.any? { |extension| filename =~ /#{Regexp.escape(extension)}$/ }
    end

    def export(visualization, user,
               user_tables_ids: nil,
               format: DEFAULT_EXPORT_FORMAT,
               data_exporter: DataExporter.new,
               visualization_export_service: Carto::VisualizationsExportService2.new,
               base_dir: exporter_folder)
      visualization_id = visualization.id
      export_dir = export_dir(visualization, base_dir: base_dir)
      tmp_dir = tmp_dir(visualization, parent_dir: export_dir)
      ensure_clean_folder(tmp_dir)

      data_exporter.export_visualization_tables(
        visualization,
        user,
        tmp_dir,
        format,
        user_tables_ids: user_tables_ids)

      visualization_json = visualization_export_service.export_visualization_json_string(visualization_id, user)
      visualization_json_file = "#{tmp_dir}/#{visualization_id}#{EXPORT_EXTENSION}"
      File.open(visualization_json_file, 'w') { |file| file.write(visualization_json) }

      safe_vis_name = Carto::FileSystem::Sanitize.sanitize_identifier(visualization.name)

      filename = "#{safe_vis_name} (#{Time.now.utc.strftime('on %Y-%m-%d at %H.%M.%S')})#{CARTO_EXTENSION}".freeze

      status = system('zip', '-r', filename, visualization_id, chdir: export_dir)
      raise "Error compressing export" unless status

      FileUtils.remove_dir(tmp_dir)

      "#{export_dir}/#{filename}"
    end
  end
end
