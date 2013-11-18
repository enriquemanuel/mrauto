require 'curb'
require 'nokogiri'
require 'json'
require 'mongo'

# INCLUDE THE CONSTANTS FILE
# all the auth credentials and urls
require_relative 'contants'


class First
	
	# All Variables that we will initialize
	# required input variable
	vip 				= String.new

	# The following variables are initialized from Opsmart
	client_name 		= String.new
	client_id			= String.new
	product_id 			= String.new
	truesight_server 	= String.new
	truesight_id		= String.new

	# The following variables are initialized from Uptime
	appserver_img		= Hash.new
	app01_ip			= String.new
	db01_ip 			= String.new

	# ==================
	# Start of functions
	# ==================

	# Initialize function to store the VIP variable in the class
	def initvar(vip)
		@vip = vip
	end


	# We are parsing Opsmart to get all the information
	# In this function we are getting all the Variables from Opsmart
	# and storing them globally
	def parse_opsmart
		
		url = OPSMART_SERVER_URL

		# initialize CURL against Opsmart
		ceasy = Curl::Easy.new(url)
		ceasy.ssl_verify_host = false
		ceasy.ssl_verify_peer = false
		ceasy.enable_cookies = true
		ceasy.follow_location = true
		ceasy.verbose = false

		# Authenticate against Opsmart
		auth_vars = "username=#{OPSMART_USERNAME}&userpass=&encoded_pw=#{OPSMART_ENC_PASSWORD}&Login=Login"
		ceasy.url = OPSMART_LOGIN_URL
		ceasy.http_post(auth_vars)
		ceasy.perform

		# Get JSON Data with Truesight Information (Watchpoint ID and Truesight Server), and the Client Name
		json_var = "start=0&limit=10&query=#{@vip}&searchtype=live&searchquery=#{@vip}"

		ceasy.url = OPSMART_TRUESIGHT_URL
		ceasy.http_post(json_var)
		ceasy.perform
		# temporary save the result ->
		json_result = ceasy.body_str

		# Get all the information from Opsmart (client id, client name, product id)
		inventory_var = "ANYFIELD=#{@vip}&searchmodule=chkInvM&searchresult=Search"
		ceasy.url = OPSMART_INVENTORY_URL
		ceasy.http_post(inventory_var)
		ceasy.perform
		# temporary save the result -> its in HTML form
		html_result = ceasy.body_str
		
		# Close the CURL connection.
		ceasy.close

		# Parse all results and save the variables accordingly
		# this is all the scraping magic
		# ========
		# 1. Parse the JSON result
		hash_result 		= JSON.parse(json_result)
		information 		= hash_result["data"][0] # temporary store all the JSON (hash) information
		@truesight_server	= "https://" +information["report_url"].split("/")[2] # get from the hash the report_url value, then split it where it finds a / and then get the third value of the array, this only includes the IP no https
		@client_name		= information["wp_name"] # get from the hash the wp_name value
		@truesight_id		= information["wp_id"] # get the hash from the wp_id value

		# ========
		# 2. Parse the HML result
		# define variables
		array_temp = Array.new

		# Initialize Nokogiri to parse
		html = Nokogiri::HTML(html_result)
		# search all the classes that are .rowdata_lb and get their children
		servers = html.css('.rowdata_lb').children
		# navigate to all the classes 
		servers.each do |server|
			# get from the entity the "value" param
			value = server.xpath('@value')
			# remove the beginning of the file
			# depending if its advanced platform or flex gen
			ad_platform = "apcprd_"
			fg_platform = "fgprd_"
			if value.to_s =~ (/#{ad_platform}/) # advanced platform
				array_temp =  value.to_s.gsub("apcprd_","").split('_a')
			elsif value.to_s =~ (/#{fg_platform}/) #flex gen platform
				array_temp =  value.to_s.gsub("fgprd","").split('_a')
			end
		end
		
		array_temp = array_temp[0].to_s.split("_")
		@client_id = array_temp[0] # from the temp array lets get the first value that is the client id
		@product_id = array_temp[1] # from the temp array lets get the second value that is the product id
	end


	# We are going one by one of all the Uptime servers declared in the Constants file
	# and getting all the Server names and Image entities
	# also we will be getting the App01 IP and DB01 IP
	def parse_uptime
		if @client_id =="" or @product_id ==""
			puts "Error, you need first to execute the function parse_opsmart"
			abort
		
		else
			# log in into each server and parse it
			# this way we are scraping every uptime server and getting all the
			@appserver_img = Hash.new
			UPTIME_SERVERS.each do |server|


				# initialize it
				ceasy = Curl::Easy.new(server)
				ceasy.ssl_verify_host = false
				ceasy.ssl_verify_peer = false
				ceasy.enable_cookies = true
				ceasy.follow_location = true
				ceasy.verbose = false
				ceasy.perform

				# log in
				ceasy.url = server
				ceasy.http_post("username=#{UPTIME_USERNAME}&password=#{UPTIME_PASSWORD}")
				ceasy.perform

				# Create the URL for the
				ceasy.url = server+UPTIME_POST_URL				
				ceasy.perform
				
				# lets scrape it
				hash = scrape_uptime(ceasy.body_str, "#{@client_id}_#{@product_id}")

				# lets manipulate the hash to get what we need
				# lets save the server that all this information corresponds
				appserver_img = Hash.new

				hash.each do |name, id|
					temp = name.split(':')[0]
					
					# lets get the APP01 and DB01 Ip for our variables
					if temp =~ (/app01/)
						@app01_ip = name.split(" ")[1].to_s.chop
						@app01_ip[0]=""
					elsif temp =~ (/db01/)
						@db01_ip = name.split(" ")[1].to_s.chop
						@db01_ip[0]=""
					end
					#storing my hash in a temporary hash
					appserver_img[temp]=id
				end
				
				# modifying the server to fit as a bson key
				server = server.split(".")[0].to_s

				# lets save our hash to the global one
				if appserver_img.length != 0
					@appserver_img[server]=appserver_img
				end
				
				
				# and close the connection
				ceasy.close
			end
		end
	end


	# We are going to store all the variables in the database
	# for this reason we need to create a function to create our bson / json data
	# then store it in the database for later use
	def save_to_mongo

		# now lets create the connection to our database
		mongo_client = Mongo::MongoClient.new
		# lets create a new database
		db = mongo_client.db("reporting")
		# lets create the collection
		# we will be storing our information here
		recess = db.collection("recess")

		# before inserting we validate if there is no actual record
		exists = recess.find("vip"=>@vip).to_a

		if exists.length != 0
			# puts "We shall update it!"
			update_time = Time.now
			recess.remove("vip" => @vip)
			updated_time = Time.now.to_s
			data = [
				{ # this is THE ONE record
				'client_name' 		=> @client_name,
				'client_id'			=> @client_id,
				'product_id'		=> @product_id,
				'truesight_server'	=> @truesight_server,
				'truesight_id'		=> @truesight_id,
				'app01_ip'			=> @app01_ip,
				'db01_ip'			=> @db01_ip,
				'vip'				=> @vip,
				'appserver_img'		=> @appserver_img,
				'updated_time'		=> updated_time
				}
			]
			# lets insert our record
			recess.insert(data)
		else
			# puts "Exists is null and we can insert the record!"
			# create the record
			create_time = Time.now.to_s
			data = [
				{ # this is THE ONE record
				'client_name' 		=> @client_name,
				'client_id'			=> @client_id,
				'product_id'		=> @product_id,
				'truesight_server'	=> @truesight_server,
				'truesight_id'		=> @truesight_id,
				'app01_ip'			=> @app01_ip,
				'db01_ip'			=> @db01_ip,
				'vip'				=> @vip,
				'appserver_img'		=> @appserver_img,
				'created_time'		=> create_time
				}
			]
			# lets insert our record
			recess.insert(data)
		end

		mongo_client.close()	
	end


	# ==========================
	# Start of Helper functions
	# ==========================

	# Helper function 
	# print all the variables to see if it actually works
	def print_global_vars
		puts "Client Name: #{@client_name}"
		puts "Client Id: #{@product_id}"
		puts "Client Product ID: #{@client_product}"
		puts "Truesight Server: #{@truesight_server}"
		puts "Truesight ID: #{@truesight_id}"
		puts "App01 IP: #{@app01_ip}"
		puts "DB01 IP: #{@db01_ip}"
		
		@appserver_img.each do |server, id|
			puts "Uptime server id with its image id: #{server}"
			id.each do |name, value|
				puts " "+name + " -> "+value
			end
		end
	end

	# Helper function
	# Created this function to return from this class the record that was inserted into the db
	# that way if you want to use anything from this record it can be
	# displayed in the screen when invoked or anything else
	# we are just returning the json data
	def return_information
		# now lets create the connection to our database
		mongo_client = Mongo::MongoClient.new
		# lets create a new database
		db = mongo_client.db("reporting")
		# lets create the collection
		# we will be storing our information here
		recess = db.collection("recess")
		# query to get all the information based on the vip
		json_data = recess.find({"vip"=>@vip}).to_a
		mongo_client.close()	
		return json_data

	end

	# Helper function
	# This function is used only for Uptime
	# It helps us parse and get only the production servers for the given client_id and product_id
	def scrape_uptime(page_as_html, client_product)
		
		#initialize the file for web scraping
		html = Nokogiri::HTML(page_as_html)

		#get all the div class="Info"
		entities = html.css('.Info')

		# define variables to use
		# two hashes, one for that is the intermediate and final use (entities_ids)
		# the other is the temp_hash that needs to be cleared from memory after use
		entities_ids = Hash.new
		temp_hash = Hash.new

		#start loop
 
		entities.each do |entity|
			# start if

			ap = "apcprd_#{client_product}"
			fg = "fgprd_#{client_product}"

			
			if entity.text =~ (/#{ap}/) or entity.text =~ (/#{fg}/) # this is the search for the client id
				
				#short version to remove things
				for_entity = entity.xpath('@for').to_s.chop.gsub("entity_[","")
				
				#server = entity.text.split(':')[0]
				server = entity.text
				#puts server + " : " + for_entity
				
				#adding to hash to get the new value
				# its looks like this now:
				# entities_ids["apcprd_100367_57480_app14"] = 42  -> this value (42) is incorrect
				# its the identifier that we need to get again from the checkbox
				entities_ids[server]=for_entity
			# end if
			end

			# now lets get the checkboxes and create a temporary hash with ALL the checkboxes
			# this can be enhanced later 
			name = entity.xpath('@name').to_s.lstrip
			id = entity.xpath('@id').to_s.lstrip.chop.gsub("entity_[","")	
			temp_hash[id]=name

		#end loop
		end

		# this will create our final hash with the correct image entity
		# it was like this:
		# entities_ids["apcprd_100367_57480_app14"]=42  -> this value is incorrect
		# will end like this:
		# entities_ids["apcprd_100367_57480_app14"]=132123123 -> this is the image entity
		entities_ids.each do|server, entity|
			image_id = temp_hash[entity].chop.gsub("entity[","")
			entities_ids[server]=image_id
		end

		#return hash from function for further use
		return entities_ids
	end

end
i = First.new
puts "We started processing everything: "+Time.now.to_s

# i.initvar("1.2.3.4")  # this vip is for client

i.parse_opsmart
i.parse_uptime
i.save_to_mongo
i.return_information
