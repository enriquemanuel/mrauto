mrauto
======

I have created the first repository to document and upload the files that I'm building in Ruby to automate the 
monthly reports created in ruby while using a few platforms including Nokogiri, CURB, JSON and Mongo

The idea behind this is to keep updating my work and don't loose it.

### How to run this

    ruby first.rb
    
At this time, it only grabs the information from the different sites and stores that informaton in Mongo.

### Steps?
The idea is to have the following steps and then have everything using Sinatra
1. Get all the information using only the IP from the URL and store it in the databse
2. Connect to all the sites using the information collected in the first step and store it locally
3. Store the images in Mongo and also automate the report to send emails
4. Scrape all the CHM clients and get all the information for all the clients 

