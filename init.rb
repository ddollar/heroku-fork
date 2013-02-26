require "rest_client"

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

    api.get_addons(from).body.each do |addon|
      if addon["name"] =~ /^heroku-postgresql:/ and !%w( heroku-postgresql:dev heroku-postgresql:basic ).include?(addon["name"])
        action("Forking #{addon["name"]}") do
          url = from_config.delete("#{addon["attachment_name"]}_URL")
          addon = api.post_addon(to, addon["name"], :fork => url).body
          name = addon["message"].match(/Attached as (\w+)\n/)[1]
          pg_url = api.get_config_vars(to).body[name]
          from_config["DATABASE_URL"] = pg_url
        end
      else
        action("Adding #{addon["name"]}") do
          api.post_addon to, addon["name"]
        end
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
  end

  alias_command "fork", "apps:fork"

private

  def fork_service
    RestClient::Resource.new(fork_host, "", Heroku::Auth.api_key)
  end

  def fork_host
    ENV["FORK_HOST"] || "https://fork.herokuapp.com"
  end

end
