require 'open-uri'
require 'json'

def mean(array)
  array.inject(0) { |sum, x| sum += x } / array.size.to_f
end
def variance(array)
  m = mean(array)
  variance = array.inject(0) { |variance, x| variance += (x - m) ** 2 }
  return variance
end
def stdev(array)
  return Math.sqrt(variance(array)/(array.size-1))
end

class Subject
  include MongoMapper::Document
  include ApplicationHelper
  # many :classifications
  set_collection_name "milky_way_subjects"

  key :project_id, ObjectId
  key :workflow_ids, Array
  key :zooniverse_id, String
  key :state, String

  key :location, Hash
  key :classification_count, Integer
  key :coords, Array

  key :metadata, Hash
  key :size, String

  key :group_id, ObjectId, :optional
  key :group_type, String, :optional
  # timestamps

  scope :near_to, lambda {|centre| where(:id => {'$in' => Subject.near(centre)}) }

  def switched?
    self.group["zooniverse_id"].in? ["GMW0000003", "GMW0000004", "GMW0000005"]
  end

  def classifications
    Classification.where(:subject_ids => [Subject.find_by_zooniverse_id(self.zooniverse_id).id])
  end

  def user_names
    self.classifications.map{|c|c.user_name}.uniq
  end

  def annotations
    self.classifications.map{|c|c.annotations}.flatten.select{|i|i["center"]}
  end

  def annotations_by_type(o="ego")
    self.annotations.select{|a| a if a["name"]==o}
  end

  def dbscan_by_type(o)
    output = { "raw"=>[], "reduced"=>[], "signal"=>{}, "noise"=>[] }

    objects = self.annotations.select{|a| a if a["name"]==o}
    objects.each do |i|
      rot = i["angle"].to_f%180
      rx = rot>90 ? i["ry"].to_f : i["rx"].to_f
      ry = rot>90 ? i["rx"].to_f : i["ry"].to_f
      output["raw"] << [i["center"][0].to_f, i["center"][1].to_f, rx, ry, (5.0/90.0)*(rot%90.0) ]
    end

    dbscan = Clusterer.new( output["raw"], {:min_points => 5, :epsilon => 20})
    dbscan.results.each do |k, arr|
      unless k==-1
        output["signal"][k] = arr.map{|i| { "x" => i[0], "y" => i[1], "rx" => i[2], "ry" => i[3], "angle" => (90.0/5.0)*i[4] } }
        avx   = arr.transpose[0].inject{|sum, el| sum+el }.to_f/arr.size
        avy   = arr.transpose[1].inject{|sum, el| sum+el }.to_f/arr.size
        avrx  = arr.transpose[2].inject{|sum, el| sum+el }.to_f/arr.size
        avry  = arr.transpose[3].inject{|sum, el| sum+el }.to_f/arr.size
        avrot = arr.transpose[4].inject{|sum, el| sum+el }.to_f/arr.size

        quality = { "qx"=>stdev(arr.transpose[0]), "qy"=>stdev(arr.transpose[1]), "qrx"=>stdev(arr.transpose[2]), "qry"=>stdev(arr.transpose[3]) }

        output["reduced"] << { "x" => avx, "y" => avy, "rx" => avrx, "ry" => avry, "angle" => (90.0/5.0)*avrot, "quality" => quality }
      else
        output["noise"] = arr.map{|i| { "x" => i[0], "y" => i[1], "rx" => i[2], "ry" => i[3], "angle" => i[4] } }
      end
    end
    return output
  end

  def dbscan
    types = ["bubble", "cluster", "ego", "galaxy"]
    result = {}
    types.each do |o|
      result[o] = self.dbscan_by_type(o)
    end
    return result
  end

  def self.near(centre)

    distance = 0.075
    regionals = []
    lows  = Subject.where(:coords => {:$elemMatch => {:$gte => centre[0]-distance, :$gte => centre[1]-distance}}).to_a
    lows.each{|s| regionals<<s if s.coords[0]<=centre[0]+distance && s.coords[1]<=centre[1]+distance } # && s.metadata["size"]=="0.1500x0.0750" }

    subjects = {}
    regionals.each do |s|
      dist = Math.sqrt( ((s.coords[0]-centre[0]) * (s.coords[0]-centre[0])) + ((s.coords[1]-centre[1]) * (s.coords[1]-centre[1])) )
      subjects[s.id] = dist
    end

    subjects.values.sort!
    return subjects.select {|k, v| v < distance}.keys

  end

  def glat
  	self.switched? ? self.coords[1].to_f : self.coords[0].to_f
  end

  def glon
  	self.switched? ? self.coords[0].to_f : self.coords[1].to_f
  end

  def width
  	self.metadata["size"].split(/x/)[0].to_f
  end

  def height
  	self.metadata["size"].split(/x/)[1].to_f
  end

  def pixel_scale
  	xs = self.width.to_f/800.0
  	ys = self.height.to_f/400.0

  	return xs==ys ? xs : "scale conflict"
  end

  def image
    self.location["standard"]
  end

  def object_count(o)
  	self.metadata["markings"] ? self.metadata["markings"][o+"_count"].to_i : 0
  end

  def empty_image?
  	if self.metadata["markings"]
  		if self.object_count("blank")>=5 && self.state=="complete" && self.classification_count<=10
  		  return true
	  	else
	  	  return false
	    end
    else
	    return false
  	end
  end

  def mag2flux(mag,band)
    f_0 = {"U" => 1810.0,"B" => 4260.0,"V" => 3540.0,"R" => 2870.0,"I" => 2250.0,"J" => 1670.0,"H" => 980.0,"K" => 620.0,"L" => 280.0,"M" => 150.0}
    if f_0.has_key?(band)
      mag ? flux = f_0[band]*10**(-mag/2.5) : 0.0
    else
      mag = ""
    end
  end

  def flux2mag(flux,band)
    f_0 = {"U" => 1810.0,"B" => 4260.0,"V" => 3540.0,"R" => 2870.0,"I" => 2250.0,"J" => 1670.0,"H" => 980.0,"K" => 620.0,"L" => 280.0,"M" => 150.0}
    if f_0.has_key?(band)
      flux ? mag = -2.5*(Math.log(flux/f_0[band]))/Math.log(10) : 0.0
    else
      flux = ""
    end
  end

  def simbad_url(radius=5, top=25)

    #Get equatorial coordinates
    eq = gal2equ(self.glon, self.glat)
    ra = eq[0]
    dec = eq[1]

    #Build URL
    url_start = "http://simbad.u-strasbg.fr/simbad/sim-tap/sync?request=doQuery&lang=ADQL&format=JSON&query="

    get_url = url_start+URI::encode("SELECT TOP #{top} basic.OID, RA, DEC, main_id, coo_bibcode, filter, flux, ident.id, otype, flux.bibcode FROM basic, flux JOIN ident USING(oidref) WHERE flux.oidref = basic.oid AND ra < #{ra+radius} AND ra > #{ra-radius} AND dec < #{dec+radius} AND dec > #{dec-radius}")

  end

  def search_simbad(radius=5, top=25)

    get_url=self.simbad_url(radius, top)
    # the_data = Rails.cache.fetch("simbad-#{radius}-#{top}", :expires_in => 6.hours) {
      json = open("#{get_url}").read
      the_data =  JSON.parse(json)
    # }

    output = Array.new
    if the_data["data"].size > 0
      map = the_data["data"].map {|item| {item[3] => {"object_name" => item[3], "type" => item[8], "bibcode" => item[4], "ra" => item[1], "dec" => item[2], item[5] => mag2flux(item[6],item[5]), "other_name" => item[7], "other_bib" => item[9] } } }
      red = map.reduce({}) {|h,pairs| pairs.each {|k,v| (h[k] ||= []) << v}; h}
      red.each do |r|
        #Collect up names and bibcodes and merge objects into single entries
        names = r[1].collect {|i| i["other_name"] }
        bibs = r[1].collect {|i| i["other_bib"] }
        obj = r[1].inject { |all, h| all.merge!(h) }

        #Clean up and format object names
        obj.delete("other_name")
        obj["all_names"] = (names).uniq!

        #Clean up and format bibcodes
        obj.delete("other_bib")
        bibs << obj["bibcode"]
        obj.delete("bibcode")
        obj["bibcodes"] = (bibs).uniq!

        #output object
        output << obj
      end
    end

    return output

  end

end
