require 'rubygems'
require 'bundler'
require 'yaml'
require 'digest/md5'
Bundler.require

$site = ARGV[0]
$site = $site.split('/').pop
$start = Time.new
directory = ARGV[1] ? ARGV[1] : $site
$queue = Queue.new
$badFile = Queue.new
$bytes = 0

concurrency = 4

# Create the directory from the base directory AND the tumblr site
directory = [directory, $site].join('/')

# Create a log and graph directory
logs = [directory, 'logs'].join('/')
graphs = [directory, 'graphs'].join('/')

puts "Downloading photos from #{$site.inspect}, concurrency=#{concurrency} ..."

# Make the download directory
FileUtils.mkdir_p(directory)

# Make the log directory
FileUtils.mkdir_p(logs)
FileUtils.mkdir_p(graphs)

threads = []
$allImages = []

def download(url)
  page = ''
  duration = Time.new - $start
  mb = $bytes / (1024.00 * 1024.00)
  speed = ($bytes / duration) / 1024
  puts "%5d/%d %3.2fMB %.0f:%02d %4.2fKB/s %s" % [$allImages.length - $queue.length, $allImages.length, mb, (duration / 60), duration.to_i % 60, speed, url]
  STDOUT.flush

  loop {
    begin
      page = Mechanize.new.get(url)
      break

    rescue Mechanize::ResponseCodeError => e
      if e.page.code == "403"
        return [false, 403]
      elsif Net::HTTPResponse::CODE_TO_OBJ[e] == 404
        puts "Fatal Error"
        $badFile << url
        return [false, 404]
      elsif Net::HTTPResponse::CODE_TO_OBJ[e] == 408
        # Take a break, man.
        sleep 1
        next
      end

    rescue Timeout::Error
      puts "Error stream (#{page_url}), #{$!} - retrying"
      sleep 1
      next

    rescue Exception => ex
      puts "Error getting file (#{url}), #{$!}"
      if ex.class == SocketError
        puts "Maybe the site is gone?"
        exit -1
      end
      break
    end
  }

  $bytes += page.body.length
 
  [true, page]
end

def parsevideo(page)
  all = [] 
  page.scan(/url="([^"]*)"/) { | list | 
    list.each { | x |
      all << x
      $queue << [:video, x]
    }
  }

  doc = Nokogiri::XML.parse(page)
  posts = (doc/'post').map {|x| x['url']}
  posts.each do | url |
    $queue << [:page, url]
  end

  all
end

def parsefile(doc)
  images = (doc/'post photo-url').select{|x| x if x['max-width'].to_i == 1280 }
  posts = (doc/'post').map {|x| x['url']}
  image_urls = images.map {|x| x.content }

  # Eliminate duplicate images.
  image_urls.sort!
  image_urls.uniq!
  
  # Eliminate images we've already downloaded
  image_urls = image_urls - $allImages

  # Add this to the list
  $allImages += image_urls
  $allImages += posts

  posts.each do | url |
    $queue << [:page, url]
  end

  image_urls.each do |url|
    $queue << [:image, url]
  end
  [images, image_urls]
end

Dir.glob("#{logs}/*") { | file |

  if file == "badurl"

    File.open(file, 'r') { | content |
      # Start the list with the bad images
      $allImages = content.split('\n')
    }

  else
    File.open(file, 'r') { | content |
      images, count = parsefile Nokogiri::XML.parse(content)

      if count.length > 0
        puts ">> #{file} +#{count.length}"
      else
        puts ">> #{file} +#{count.length} (ignored)"
      end
    }

  end
}


def graphGet(file)
  file.match(/.GET...([^']*)/) { | x | 
    url = ['http://', $site, x].join('')
    puts url
  }
end

concurrency.times do 
  threads << Thread.new {
    Thread.abort_on_exception = true

    loop {
      begin
        type, url = $queue.pop
        break if url == "STOP"
      rescue
        puts "Queue failure, trying again, #{$!}"
        next
      end
      
      filename = url.split('/').pop

      if type == :video
        videoList = []
        success, page = download(url)
        if success
          page.body.scan(/src=.x22([^\\]*)/) { | list |
            list.each { | x |
              videoList << x if x.match(/video_file/)
            }
          }

          videoList.each { | url |
            filename = url.split('/').pop + ".mp4"
            
            unless File.exists?("#{directory}/#{filename}")
              File.open("#{directory}/vids", 'a') { | f |
                realurl=`curl -sI #{url} | grep ocation | awk ' { print $2 } '`
                f.write("#{realurl.gsub(/#.*/, '')}")
                print '.'
                STDOUT.flush
              }
            end
          }
        end
      elsif type == :image
        unless File.exists?("#{directory}/#{filename}")
          success, file = download(url)
          file.save_as("#{directory}/#{filename}") if success
          # puts "#{$allImages.length - $queue.length}/#{$allImages.length} #{$site} #{filename}"
        end
      elsif type == :page
        unless File.exists?("#{graphs}/#{filename}")
          success, file = download(url)
          if success
            file.save_as("#{graphs}/#{filename}") 
            graphGet(file.body)
          end
          # puts "#{$allImages.length - $queue.length}/#{$allImages.length} #{$site} #{url} (graph)"
        end
      end
    }
  }
end

num = 50
start = 0
loop do
  page_url = "http://#{$site}/api/read?type=photo&num=#{num}&start=#{start}"

  success, page = download(page_url)

  if !success
    puts "Failed to get #{page_url}"
    break
  end

  doc = Nokogiri::XML.parse(page.body)
  md5 = Digest::MD5.hexdigest(page.body)
  logFile = [logs, md5].join('/')

  if File.exists?(logFile)
    puts "Guessing that we have everything else. Not downloading any more image pages."
    break
  else
    images, added = parsefile doc

    #puts "| #{page_url} +#{added.count}"

    # If this file added nothing, then break here and don't save it.
    if added.count == 0
      puts "Guessing that we have everything else. Not downloading any more image pages."
      break
    end
    
    # Log the content that we are getting
    File.open(logFile, 'w') { | f |
      f.write(doc.to_s)
    }

    if images.count < num
      puts "All image pages downloaded."
      break
    end
  end

  start += num
end

num = 50
start = 0
loop do
  page_url = "http://#{$site}/api/read?type=video&num=#{num}&start=#{start}"

  success, page = download(page_url)
  if success
    md5 = Digest::MD5.hexdigest(page.body)
    logFile = [logs, md5].join('/')

    unless File.exists?(logFile)
      # Log the content that we are getting
      File.open(logFile, 'w') { | f |
        f.write(page.body)
      }
    end

    videos = parsevideo page.body

    #puts "| #{page_url} +#{videos.count}"
    
    if videos.count < num
      puts "All pages downloaded. Waiting for videos"
      break
    end

    start += num
  end
end

concurrency.times do 
  $queue << [:control, "STOP"]
end

threads.each{|t| t.join }

puts "Ok done. Adding 403s to blacklist"
loop {
  break if $badFile.empty?
  url = $badFile.pop

  File.open("#{logs}/badurl", "w+") do | f1 |
    f1.write(url)
  end
}