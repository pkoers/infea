class EmailProcessor
  def initialize(email)
    @email = email
  end

  def process
    email.attachments.each do |attachment|
      if attachment.content_type.start_with?('text/plain')
        attachment_text = attachment.read
        puts "Received email from #{email.from} with subject '#{email.subject}' and attachment '#{attachment.original_filename}'"
        full_subject = "#{email.subject}"
        add = check_flightnumber_length("#{full_subject[2,4]}".to_i)
        # reading the origin and destination
        puts "Origin #{full_subject[17 + add, 3]}"
        origin = "#{full_subject[17 + add, 3]}"
        puts "Destination #{full_subject[20 + add, 3]}"
        # Read the registration code from the first two lines of the attachment
        lines = attachment_text.split("\n")
        lines.each do |line|
          if line.start_with?('AN')
            registration_code = line[3, 5]
            rego_email = read_regos(registration_code)
            from_domain = select_sender(registration_code)
            if rego_email != "UNK"
              replyto = station_array(origin, registration_code).join(", ")
              pdfprocess(attachment_text, full_subject.gsub('/', ''), full_subject, rego_email, replyto, from_domain)
            else
              puts "Unknown Aircraft #{registration_code}"
            end

            break
          end
        end
      end
    end
  end

  # Enter an entry in the System Alert log (Alert ID, Content)
  def log_alert(alert_id, alert_content)
    alert = SystemAlert.new
    alert.alert_id = alert_id
    alert.alert_content = alert_content
    alert.save

    # Define the Slack URL to send the POST request to
    url = URI.parse('https://hooks.slack.com/triggers/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')

     # Create a hash representing the JSON payload to send to Slack
     payload = {
      "Notification" => "[#{alert.alert_id}] #{alert.alert_content}"
    }
    # Convert the hash to JSON format
    json_payload = payload.to_json
    # Create a new HTTP POST request
    request = Net::HTTP::Post.new(url.path)
    # Set the request headers to indicate that you are sending JSON data
    request.content_type = 'application/json'
    request['Accept'] = 'application/json'
    # Set the request body to the JSON payload
    request.body = json_payload
    # Create an HTTP object and send the request
    http = Net::HTTP.new(url.host, url.port)
    http.use_ssl = (url.scheme == 'https')
    response = http.request(request)
    # Check the response
    if response.code == '200'
      # Successful response
      puts "Response: #{response.body}"
    else
      # Handle error
      puts "Error: #{response.code} - #{response.message}"
    end

  end

  # Check the length of the flight number, if less then 1000 return -1 else return 0
  def check_flightnumber_length(check)
    check < 1000 ? i = -1 : i = 0
    return i
  end

  # Because of implementing a new outbound email domain, we need to set the correct sender
  def select_sender(rego)
    if rego == "PHXXX"
      return_from = "loadsheet@mixty.com"
    else
      return_from = "loadsheet@datatechground.com"
    end
    return return_from
  end

  # origin is the iata station code found in the inbound email
  # this def searches the table for the reply-to email adresses
  def station_array(origin, rego)
    station = Station.find_by(iata_station_code: origin).try(:id)
    # station 99999 is assigned when the station is not known in the table
    station ||= 99999
    # add alert in the system alerts log when station == 99999
    log_alert(2001, "#{origin} not defined") if station == 99999
    output = Email.where(station_id: station).pluck(:email_address)
    # Add the addresses that always have to be used as a reply-to
    # output << "loadsheet@germanairways.com"
    if read_owner(rego) == "UNK"
      log_alert(2002,"#{rego} does not have an owner")
      return output
    else
      output << read_owner(rego)
      return output
    end
  end

  # rego is the registration of the aircraft, used to find the owner
  def read_owner(rego)
    #look for the email address of the aircraft owner
    aircraft = Aircraft.find_by(aircraft: rego)
    # set the email address of the aircraft owner
    # owner = aircraft.owner.email_address
    aircraft.owner_id.nil? ? owner = "UNK" : owner = aircraft.owner.email_address
    return owner
  end

  # rego is the registration of the aircraft
  def read_regos(rego)
    # look for a Aircraft and return the associated email address
    returned_rego = Aircraft.find_by(aircraft: rego)
    # when no rego found in the table, return UNK otherwise return the rego
    returned_rego.nil? ? returned_rego = "UNK" : returned_rego = returned_rego.email_address
    # add alert in the system alerts log when returned_rego == UNK
    log_alert(3001, "Unknown Registration received #{rego}") if returned_rego == "UNK"
    return returned_rego
  end

  def pdfprocess(attachment_text, file_name, full_subject, email_user, replyto, from_domain)
    # Store the text attachment in a temporary file
    text_file = Tempfile.new('text_attachment')
    text_file.write(attachment_text)
    text_file.rewind

    # Convert the text file to a PDF file and store it in another temporary file
    # file_name = 'KLM Loadsheet' # Set a default file name
    pdf_file = Tempfile.new([file_name, '.pdf']) # Create PDF file with the same name

    Prawn::Document.generate(pdf_file.path) do
      text File.read(text_file.path)
    end

    # email_user = 'mail.alteafm.database@klm.com'

    # Attach the stored PDF file to the email and send it
    SendMailer.send_email(email_user, file_name, File.read(pdf_file.path), full_subject, replyto, from_domain).deliver_now

    # Close and unlink the temporary files
    text_file.close
    text_file.unlink
    pdf_file.close
    pdf_file.unlink
  end

 # def post(user)
 #   SendMailer.send_email(user).deliver_now
 # end

  private

  attr_reader :email
end
