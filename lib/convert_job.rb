require 'jobs_common/static_manager'

class ConvertJob
  @queue = :convert
  
  class << self
    def perform(upload_id, filename, density = 150)
      mongoid_conf = YAML::load_file(Rails.root.join('config/mongoid.yml'))[Rails.env]
      
    	@upload_id = upload_id
    	@filename  = filename
    	@db = Mongo::Connection.new(mongoid_conf['host']).db(mongoid_conf['database'])

      setup_environment
      
      begin
        get_the_source_file

        slice_by_pages(@upload_id)
        
        @static_manager = StaticManager.new(@upload_id)
      	@static_manager.create_upload_dir
      	
      	total_pages_to_convert = `ls *-page-*.pdf | wc -l`.strip.to_i
      	
      	@db.collection('uploads').update({ "_id" => BSON::ObjectID(@upload_id) }, {
    			"$set" => { "total_pages" => total_pages_to_convert }
    		})

      	converted_count = 0

        Dir.new(".").each do |filename|
        	if filename.match(/.pdf$/)
        		out_file = convert_file(filename, density)
        		
        		converted_count += 1
        		
        		@db.collection('uploads').update({ "_id" => BSON::ObjectID(@upload_id) }, {
        		  "$set" => { "already_converted" => converted_count }
        		})
        		
        		File.delete(filename)
        	end
        end
        
        # remove the source file
        File.delete(@upload_id)
        
        tar_filename = @upload_id + ".tar"
        
        `tar cf #{tar_filename} *`
        
        @static_manager.upload_and_unpack_converted_file(tar_filename)
        
        set_converted_data(@static_manager.host)
      rescue
        # TODO: log this somewhere?
        raise
      ensure
        clean_environment
      end
    end
    
    
  	protected
  	
  	def setup_environment
  		`mkdir /tmp/#{@upload_id}`
  		Dir.chdir("/tmp/" + @upload_id)
  	end
  	
  	def clean_environment
  		#Dir.chdir("..")
  		`rm -rf /tmp/#{@upload_id}` # all sliced pages of the source file
  	end
  	
  	def slice_by_pages(filename)
  		pdftk_cmd = `which pdftk`.strip

  		`#{pdftk_cmd} #{filename} burst output \"#{filename}-page-%06d.pdf\"`
  	end
  	
  	def convert_file(filename, density = 100)
  		convert_cmd = `which convert`.strip

  		output_filename = filename.gsub(".pdf", "").gsub("-page", "") + ".png"

  		`#{convert_cmd} -density #{density} "#{filename}" "#{output_filename}"`

  		output_filename
  	end
  	
  	# moves uploaded binary file from mongo db to the local fs
  	def get_the_source_file
  		mongo_filename = @upload_id + "/" + @filename
    	gridfs_file = Mongo::GridFileSystem.new(@db).open(mongo_filename, 'r')
    	File.open(@upload_id, 'w') { |f| f.write(gridfs_file.read) }
  	end
  	
  	# sets the converted flag to true and add some fields
  	def set_converted_data(static_host)
  	  doc_data = parse_doc_data
  		#doc_data = ""
  		#File.open("doc_data.txt", "r") do |file|
  		#	file.each_line do |line|
  		#		doc_data += line
  		#	end
  		#end
  		
  		@db.collection('uploads').update({ "_id" => BSON::ObjectID(@upload_id) }, {
  			"$set" => {
  				"converted"   => true,
  				"static_host" => static_host,
  				"doc_data"    => doc_data
  			}
  		})
  	end
  	
  	# parses doc_data.txt file to array of hashes
    def parse_doc_data
      begin
        raw_data = File.open("doc_data.txt", "r").read
        ary_data = raw_data.split(/\n/)

        parsed_info = []

        ary_data.each_with_index do |elem, i|
          next_elem = ary_data[i + 1]

          if (elem.match(/InfoKey/) && (next_elem.match(/InfoValue/)))
            parsed_info.push(elem.split(/\:/, 2)[1].strip => next_elem.split(/\:/, 2)[1].strip)
          else
            if (!elem.match(/InfoValue/))
              parsed_info.push(elem.split(/\:/, 2)[0].strip => elem.split(/\:/, 2)[1].strip)
            end
          end
        end
      rescue
        parsed_info = []
      end

      return parsed_info
    end
  end
end