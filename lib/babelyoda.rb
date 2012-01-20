BABELYODA_PATH = File.expand_path(File.join(File.dirname(__FILE__), '..'))

require 'awesome_print'
require 'fileutils'

require_relative 'babelyoda/genstrings'
require_relative 'babelyoda/git'
require_relative 'babelyoda/ibtool'
require_relative 'babelyoda/keyset'
require_relative 'babelyoda/localization_key'
require_relative 'babelyoda/localization_value'
require_relative 'babelyoda/logger'
require_relative 'babelyoda/rake'
require_relative 'babelyoda/specification'
require_relative 'babelyoda/tanker'
require_relative 'babelyoda/xib'

desc "Do a full localization cycle: push new strings, get translations and merge them"
task :babelyoda => ['babelyoda:push', 'babelyoda:pull'] do
end

namespace :babelyoda do
  
  file 'Babelfile' do
    Babelyoda::Specification.generate_default_babelfile
  end
  
  desc "Create a basic bootstrap Babelfile"
  task :init => 'Babelfile' do
  end
  
  Babelyoda::Rake.spec do |spec|
    
    desc "Extract strings from sources"
    task :extract_strings do
      spec.scm.transaction("[Babelyoda] Extract strings from sources") do 
        $logger.info "Extracting strings from sources..."
        dev_lang = spec.development_language
        Babelyoda::Genstrings.run(spec.source_files, dev_lang) do |keyset|
          old_strings_filename = strings_filename(keyset.name, dev_lang)
          old_strings = Babelyoda::Strings.new(old_strings_filename, dev_lang).read
          old_strings.merge!(keyset)
          old_strings.save!
          $logger.debug "#{old_strings_filename}: #{old_strings.keys.size} keys"
        end
      end
    end
    
    desc "Extract strings from XIBs"
    task :extract_xib_strings do
      spec.scm.transaction("[Babelyoda] Extract strings from XIBs") do 
        $logger.info "Extracting .strings from XIBs..."
        spec.xib_files.each do |xib_filename|
          xib = Babelyoda::Xib.new(xib_filename, spec.development_language)
          next unless xib.extractable?(spec.development_language)
          keyset = xib.strings
          unless keyset.empty?
            $logger.debug "#{xib_filename} => #{xib.strings_filename}"
            Babelyoda::Strings.save_keyset(keyset, xib.strings_filename, spec.development_language)
          end
        end
      end
    end
    
    desc "Extracts localizable strings into the corresponding .strings files"
    task :extract => [:extract_strings, :extract_xib_strings] do
    end
    
    desc "Drops empty local keysets"
    task :drop_empty_strings do
      spec.scm.transaction("[Babelyoda] Drop empty .strings files") do 
        $logger.info "Dropping empty .strings files..."
        files_to_drop = []
        spec.strings_files.each do |filename|
          strings = Babelyoda::Strings.new(filename, spec.development_language).read!
          if strings.empty?
            files_to_drop << filename
            spec.localization_languages.each do |language|
              localized_filename = File.localized(filename, language)
              files_to_drop << localized_filename if File.exist?(localized_filename)
            end
          end
        end
        files_to_drop.each do |filename|
          $logger.info "REMOVED empty file: #{filename}"
          FileUtils.rm filename
        end
      end
    end
    
    desc "Create remote keysets for local keysets"
    task :create_keysets => [:extract, :drop_empty_strings] do
      $logger.info "Creating remote keysets for local keysets..."
      remote_keyset_names = spec.engine.list
      spec.strings_files.each do |filename|
        keyset_name = Babelyoda::Keyset.keyset_name(filename)
        if remote_keyset_names.include?(keyset_name)
          $logger.debug "Tanker: An existing keyset found: #{keyset_name}"
          next 
        end
        strings = Babelyoda::Strings.new(filename, spec.development_language).read!
        unless strings.empty?
          spec.engine.create(keyset_name)
          $logger.debug "Tanker: Created NEW keyset: #{keyset_name}"
        end
      end
    end
    
    desc "Drops remote keys not found in local keysets"
    task :drop_orphan_keys => :create_keysets do
      $logger.info "Dropping orphan keys..."
      spec.strings_files.each do |filename|
        strings = Babelyoda::Strings.new(filename, spec.development_language).read!
        $logger.debug "Processing keyset: #{strings.name}"
        remote_keyset = spec.engine.load_keyset(strings.name)
        original_keys_size = remote_keyset.keys.size
        remote_keyset.keys.delete_if do |key, value|
          unless strings.keys.has_key?(key)
            $logger.debug "Found orphan key: #{key}"
            true
          else
            false
          end
        end
        next if original_keys_size == remote_keyset.keys.size
        unless remote_keyset.empty?
          $logger.debug "Keys removed: #{original_keys_size - remote_keyset.keys.size}, keyset REPLACED."
          spec.engine.replace(remote_keyset)
        else
          $logger.debug "All keys removed: keyset DELETED."
          spec.engine.drop_keyset!(remote_keyset.name)
        end
      end
    end
    
    desc "Pushes resources to the translators"
    task :push => :drop_orphan_keys do
      $logger.info "Pushing local keys to the remote..."
      spec.strings_files.each do |filename|
        strings = Babelyoda::Strings.new(filename, spec.development_language).read!
        $logger.debug "Processing keyset: #{strings.name}"
        remote_keyset = spec.engine.load_keyset(strings.name, nil, :unapproved)
        result = remote_keyset.merge!(strings, preserve: true)
        remote_keyset.ensure_languages!(spec.all_languages)
        if result[:new] > 0 || result[:updated] > 0
          spec.engine.replace(remote_keyset)
          $logger.debug "New keys: #{result[:new]} Updated keys: #{result[:updated]}"
        end
      end
    end
    
    desc "Fetches remote strings and merges them down into local .string files"
    task :fetch_strings do
      spec.scm.transaction("[Babelyoda] Merge in remote translations") do 
        $logger.info "Fetching remote translations..."
        spec.strings_files.each do |filename|
          keyset_name = Babelyoda::Keyset.keyset_name(filename)
          remote_keyset = spec.engine.load_keyset(keyset_name, nil, :unapproved)
          remote_keyset.drop_empty!
          spec.all_languages.each do |language|
            keyset_filename = strings_filename(keyset_name, language)
            Babelyoda::Strings.save_keyset(remote_keyset, keyset_filename, language)
            $logger.debug "#{keyset_filename}"
          end
        end
      end
    end
    
    desc "Incrementally localizes XIB files"
    task :localize_xibs do
      spec.scm.transaction("[Babelyoda] Localize XIB files") do 
        $logger.info "Translating XIB files..."
        spec.xib_files.each do |filename|
          xib = Babelyoda::Xib.new(filename, spec.development_language)
          if xib.localizable?
            xib.import_strings(spec.scm)
            spec.localization_languages.each do |language|
              xib.localize_incremental(language, spec.scm)
            end
          else
            $logger.warn "#{filename} has no localizable resources. No localization needed."
          end
        end
      end
      
      spec.scm.transaction("[Babelyoda] Update XIB SHA1 version refs") do 
        spec.xib_files.each do |filename|
          spec.scm.store_version!(filename)
        end
      end
    end

    desc "Pull remote translations"
    task :pull => [:fetch_strings, :localize_xibs] do
    end
    
    desc "Verifies all local translations are present"
    task :verify do
      combined_keyset = Babelyoda::Keyset.new('babelyoda.verify')
      spec.strings_files.each do |filename|
        dev_lang_strings = Babelyoda::Strings.new(filename, spec.development_language).read
        combined_keyset.merge!(dev_lang_strings)
        spec.localization_languages.each do |language|
          lang_strings = Babelyoda::Strings.new(filename, language).read
          combined_keyset.merge!(lang_strings)
        end
      end
      $logger.info "#{spec.development_language}: #{combined_keyset.keys.size} keys"
      total_missing_count = combined_keyset.keys.size
      
      present = {}
      spec.localization_languages.each do |language|
        present[language] = Babelyoda::Keyset.new("babelyoda.verify.#{language}")
      end
      combined_keyset.drop_empty!
      combined_keyset.keys.each_value do |key|
        spec.localization_languages.each do |lang|
          present[lang.to_sym].merge_key!(key) if key.values.has_key?(lang.to_sym)
        end
      end
      spec.localization_languages.each do |language|
        count = present[language].keys.size
        total_missing_count -= count
        $logger.error "#{language}: #{combined_keyset.keys.size - count} keys (#{count} translations missing)" if count > 0
      end
      exit 1 if total_missing_count > 0
    end
    
    namespace :remote do
      
      desc "List remote keysets"
      task :list do
        ap spec.engine.list
      end
      
      desc "Drop remote keysets in KEYSETS"
      task :drop_keysets do
        if ENV['KEYSETS']
          keysets = ENV['KEYSETS'].split(',')
          if keysets.include?('*')
            keysets = spec.engine.list
            $logger.info "Dropping ALL keysets: #{keysets}"
          else
            $logger.info "Dropping keysets: #{keysets}"            
          end
          keysets.each do |keyset_name|
            $logger.debug "Dropping: #{keyset_name}"
            spec.engine.drop_keyset!(keyset_name)
          end
        else
          $logger.error "Please provide keyset names to drop in the KEYSET environment variable. " +
                        "Separate by commas. Use * for ALL."
        end
      end

    end
  
  end
end

def strings_filename(keyset_name, lang)
  if keyset_name.match(/\//)
    File.join(File.dirname(keyset_name), "#{lang}.lproj", "#{File.basename(keyset_name)}.strings")
  else
    File.join("#{lang}.lproj", "#{keyset_name}.strings")
  end
end
