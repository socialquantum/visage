#!/usr/bin/env ruby

require 'pathname'
@root = Pathname.new(File.dirname(__FILE__)).parent.expand_path
$: << @root.to_s

require 'sinatra/base'
require 'haml'
require 'lib/visage-app/profile'
require 'lib/visage-app/helpers'
require 'lib/visage-app/config'
require 'lib/visage-app/config/file'
require 'lib/visage-app/collectd/rrds'
require 'lib/visage-app/collectd/json'
require 'lib/visage-app/types'
require 'yajl/json_gem'

module Visage
  class Application < Sinatra::Base
    @root = Pathname.new(File.dirname(__FILE__)).parent.expand_path
    set :public, @root.join('lib/visage-app/public')
    set :views,  @root.join('lib/visage-app/views')

    helpers Sinatra::LinkToHelper
    helpers Sinatra::PageTitleHelper

    configure do
      Visage::Config.use do |c|
        # FIXME: make this configurable through file
        c['rrddir'] = ENV["RRDDIR"] ? Pathname.new(ENV["RRDDIR"]).expand_path : Pathname.new("/var/lib/collectd/rrd").expand_path
        c['types']  = ENV["TYPES"] ? Visage::Types.new(:filename => ENV["TYPES"]) : Visage::Types.new
      end

      # Load up the profile.yaml. Creates it if it doesn't already exist.
      Visage::Profile.load
    end
  end

  class Profiles < Application
    get '/' do
      redirect '/profiles'
    end

    get '/profiles/:url' do
      @profile = Visage::Profile.get(params[:url])
      raise Sinatra::NotFound unless @profile
      @start  = params[:start]
      @finish = params[:finish]
      @live   = params[:live] ? true : false
      if params[:split]=="true"
        haml :profile
      else
        haml :profile_merged
      end
    end

    get '/profiles' do
      @profiles = Visage::Profile.all(:sort => params[:sort])
      haml :profiles
    end
  end


  class Builder < Application

    get "/builder" do
      if params[:submit] == "create"
        @profile = Visage::Profile.new(params)

        if @profile.save
          redirect "/profiles/#{@profile.url}"
        else
          haml :builder
        end
      else
        @profile = Visage::Profile.new(params)

        haml :builder
      end
    end

    # infrastructure for embedding
    get '/javascripts/visage.js' do
      javascript = ""
      %w{raphael-min g.raphael g.line mootools-1.2.3-core mootools-1.2.3.1-more graph}.each do |js|
        javascript += File.read(@root.join('lib/visage-app/public/javascripts', "#{js}.js"))
      end
      javascript
    end

  end

  class JSON < Application

    # JSON data backend
    mime_type :json,  "application/json"
    mime_type :jsonp, "text/javascript"

    before do
      content_type :jsonp
    end

    def merge_l1 l,r
      return l if r=={}
      {[r.keys.first, l.keys.first].join(',')=>merge_add(l.values.first, r.values.first)}
    end

    def merge_add l,r
      return r unless l
      l.each do |k, v|
        rv=r[k]
        next unless rv && (rv.class == v.class)
        if rv.kind_of?(Hash)
          l[k]=merge_add(v, rv)
        elsif rv.kind_of?(Array)
          l[k]=v.map { |vv|rvv=rv.shift; vv.to_f+rvv.to_f if vv.kind_of?(Float) || rvv.kind_of?(Float) }
        else
          l[k]=v
        end

      end
      l
    end

    # /data/:host/:plugin/:optional_plugin_instance
    get %r{/data/([^/]+)/([^/]+)((/[^/]+)*)} do
      host = params[:captures][0].gsub("\0", "")
      plugin = params[:captures][1].gsub("\0", "")
      plugin_instances = params[:captures][2].gsub("\0", "")
      start  = params[:start]
      finish = params[:finish]

      res={}
      host.split(",").sort.each do |h|
      collectd = CollectdJSON.new(:rrddir => Visage::Config.rrddir)
      json = collectd.json(:host             => h,
                           :plugin           => plugin,
                           :plugin_instances => plugin_instances,
                           :start            => start,
                           :finish           => finish)

        res=merge_l1  ::JSON.parse(json),res
      end
      # if the request is cross-domain, we need to serve JSONP
      maybe_wrap_with_callback(::JSON.generate(res))
    end

    get %r{/data/([^/]+)} do
      host = params[:captures][0].gsub("\0", "")
      metrics = Visage::Collectd::RRDs.metrics(:host => host)

      json = { host => metrics }.to_json
      maybe_wrap_with_callback(json)
    end

    get %r{/data(/)*} do
      hosts = Visage::Collectd::RRDs.hosts
      json = { :hosts => hosts }.to_json
      maybe_wrap_with_callback(json)
    end

    # wraps json with a callback method that JSONP clients can call
    def maybe_wrap_with_callback(json)
      params[:callback] ? params[:callback] + '(' + json + ')' : json
    end

  end

  class Meta < Application
    get '/meta/types' do
      Visage::Config.types.to_json
    end
  end
end
