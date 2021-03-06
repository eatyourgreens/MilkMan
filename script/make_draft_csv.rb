# Set parameters
o = "ego"
threshold_fraction = 0.5

# Run through images
Subject.each do |s|
  puts "#{s.zooniverse_id}, #{s.image}, #{s.glat}, #{s.glon}, #{s.classification_count}, #{s.object_count(o)}, #{s.object_count(o).to_f/s.classification_count.to_f}" if s.metadata["markings"] && s.object_count(o) > s.classification_count*threshold_fraction && s.classification_count>=10
end
