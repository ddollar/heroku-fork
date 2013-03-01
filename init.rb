require "rest_client"

class Heroku::API
  def get_dyno_types(app)
    request(
      :expects  => 200,
      :method   => :get,
      :path     => "/apps/#{app}/dyno-types"
    )
  end
end

class Heroku::Command::Apps < Heroku::Command::Base

  # apps:fork [NEWNAME]
  #
  # fork an app
  #
  # -r, --region REGION # specify a region
  #
  def fork
    from = app
    to = shift_argument || "#{from}-#{(rand*1000).to_i}"

    from_info = api.get_app(from).body
    to_tier   = from_info["tier"] == "legacy" ? "production" : from_info["tier"]

    action("Creating fork #{to}") do
      api.post_app({
        :name   => to,
        :region => options[:region],
        :tier   => to_tier
      })
    end

    action("Copying slug") do
      fork_service["/apps/#{app}/copy/#{to}"].post("")
    end

    from_config = api.get_config_vars(from).body
    from_addons = api.get_addons(from).body

    from_addons.each do |addon|
      to_addon = action("Adding #{addon["name"]}") do
        api.post_addon(to, addon["name"]).body
      end
      if addon["name"] =~ /^heroku-postgresql:/
        wait_for_db to, to_addon
        check_for_pgbackups! from
        check_for_pgbackups! to
        migrate_db addon, from, to_addon, to
      end
    end

    to_config = api.get_config_vars(to).body

    action("Copying config vars") do
      diff = from_config.inject({}) do |ax, (key, val)|
        ax[key] = val unless to_config[key]
        ax
      end
      api.put_config_vars to, diff
    end

    puts "Your app fork is at:"
    puts "https://#{to}.herokuapp.com/"
  end

  alias_command "fork", "apps:fork"

private

  def fork_service
    RestClient::Resource.new(fork_host, "", Heroku::Auth.api_key)
  end

  def fork_host
    ENV["FORK_HOST"] || "https://fork.herokuapp.com"
  end

  def check_for_pgbackups!(app)
    unless api.get_addons(app).body.detect { |addon| addon["name"] =~ /^pgbackups:/ }
      action("Adding pgbackups:plus to #{app}") do
        api.post_addon app, "pgbackups:plus"
      end
    end
  end

  def migrate_db(from_addon, from, to_addon, to)
    transfer = nil

    action("Creating database backup from #{from}") do
      from_config = api.get_config_vars(from).body
      from_attachment = from_addon["attachment_name"]
      pgb = Heroku::Client::Pgbackups.new(from_config["PGBACKUPS_URL"])
      transfer = pgb.create_transfer(from_config["#{from_attachment}_URL"], from_attachment, nil, "BACKUP", :expire => "true")
      error transfer["errors"].values.flatten.join("\n") if transfer["errors"]
      loop do
        transfer = pgb.get_transfer(transfer["id"])
        error transfer["errors"].values.flatten.join("\n") if transfer["errors"]
        break if transfer["finished_at"]
        sleep 1
        print "."
      end
      print " "
    end

    action("Restoring database backup to #{to}") do
      to_config = api.get_config_vars(to).body
      to_attachment = to_addon["message"].match(/Attached as (\w+)_URL\n/)[1]
      pgb = Heroku::Client::Pgbackups.new(to_config["PGBACKUPS_URL"])
      transfer = pgb.create_transfer(transfer["public_url"], "EXTERNAL_BACKUP", to_config["#{to_attachment}_URL"], to_attachment)
      error transfer["errors"].values.flatten.join("\n") if transfer["errors"]
      loop do
        transfer = pgb.get_transfer(transfer["id"])
        error transfer["errors"].values.flatten.join("\n") if transfer["errors"]
        break if transfer["finished_at"]
        sleep 1
        print "."
      end
      print " "
    end
  end

  def pg_api
    RestClient::Resource.new "https://postgres-starter-api.heroku.com/client/v11/databases", Heroku::Auth.user, Heroku::Auth.password

  end

  def wait_for_db(app, attachment)
    attachments = api.get_attachments(app).body.inject({}) { |ax,att| ax.update(att["name"] => att["resource"]["name"]) }
    attachment_name = attachment["message"].match(/Attached as (\w+)_URL\n/)[1]
    loop do
      waiting = json_decode(pg_api["#{attachments[attachment_name]}/wait_status"].get.to_s)["waiting?"]
      break unless waiting
    end
  end

end
