require 'xcodeproj'
project_path = 'ios/Runner.xcodeproj'
project = Xcodeproj::Project.open(project_path)

runner_target = project.targets.find { |t| t.name == 'Runner' }
embed_phase = runner_target.copy_files_build_phases.find { |p| p.name == 'Embed Foundation Extensions' }

unless embed_phase
  embed_phase = runner_target.new_copy_files_build_phase('Embed Foundation Extensions')
  embed_phase.dst_subfolder_spec = '13' # Plugins
end

# Find the products
share_appex = project.products.find { |p| p.path == 'ShareBankMessage.appex' }
shortcuts_appex = project.products.find { |p| p.path == 'BankMessageShortcuts.appex' }

# Add to embed phase if not already there
unless embed_phase.files_references.include?(share_appex)
  embed_phase.add_file_reference(share_appex)
end

unless embed_phase.files_references.include?(shortcuts_appex)
  embed_phase.add_file_reference(shortcuts_appex)
end

project.save
puts "Successfully added extensions to Embed phase."
