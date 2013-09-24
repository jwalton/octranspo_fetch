# OC Transpo

require "rest-client"
require 'nokogiri'
require 'time'
require 'lru_redux'

class OCTranspo
    # Create a new OCTranspo
    #
    # Arguments:
    #   options[:application_id]: (String) Your application ID, assigned by OC Transpo.
    #   options[:application_key]: (String) Your application key, assigned by OC Transpo.
    #
    def initialize(options)
        @app_id = options[:application_id]
        @app_key = options[:application_key]
        @next_trips_cache = LruRedux::Cache.new(NEXT_TRIPS_CACHE_SIZE)
        @route_summary_cache = LruRedux::Cache.new(ROUTE_CACHE_SIZE)
        @api_calls = 0
        @cache_hits = 0
        @cache_misses = 0
    end

    def clear_cache()
        @next_trips_cache.clear()
        @route_summary_cache.clear()
    end

    # Returns the number of API calls made by this instance since it was created.
    def requests()
        return @api_calls
    end

    def cache_stats()
        return {hits: @cache_hits, misses: @cache_misses}
    end

    # Get a list of routes for a specific stop.
    #
    # Returns a {stop, stop_description, routes: [{route, direction_id, direction, heading}]} object.
    # Note that route data is cached.
    #
    # Arguments:
    #     stop: (String) The stop number.
    #     options[:max_cache_time]: (Integer) Maximum cache age, in seconds.  If cached data is
    #       available and is newer than this, then the cached value will be returned.  Defaults to
    #       one day.
    #
    def get_route_summary_for_stop(stop, options={})
        max_cache_time = (options[:max_cache_time] or 60*60*24)
        cached_result = @route_summary_cache[stop]
        if !cached_result.nil? and ((cached_result[:time] + max_cache_time) > Time.now.to_i)
            @cache_hits += 1
            return cached_result[:route_summary]
        end
        @cache_misses += 1

        xresult = fetch "GetRouteSummaryForStop", "stopNo=#{stop}"

        result = {
            stop: get_value(xresult, "t:StopNo"),
            stop_description: get_value(xresult, "t:StopDescription"),
            routes: []
        }

        xresult.xpath('t:Routes/t:Route', OCT_NS).each do |route|
            result[:routes].push({
                route: get_value(route, "t:RouteNo"),
                direction_id: get_value(route, "t:DirectionID"),
                direction: get_value(route, "t:Direction"),
                heading: get_value(route, "t:RouteHeading")
            })
        end

        if result[:routes].length == 0
            raise "No routes found"
        end

        @route_summary_cache[stop] = {
            route_summary: result,
            time: Time.now.to_i
        }

        return result
    end

    # Get the next three trips for the given stop.  Note this may return data for the same route
    # number in multiple headings.
    #
    # Arguments:
    #     stop: (String) The stop number.
    #     route_no: (String) The route number.
    #     options[:max_cache_time]: (Integer) Maximum cache age, in seconds.  If cached data is
    #       available and is newer than this, then the cached value will be returned.  Defaults
    #       to five minutes.
    #
    def get_next_trips_for_stop(stop, route_no, options={})
        max_cache_time = (options[:max_cache_time] or 60*5)

        # Return result from cache, if available
        cache_key = "#{stop}-#{route_no}"
        cached_result = @next_trips_cache[cache_key]
        if !cached_result.nil? and ((cached_result[:time] + max_cache_time) > Time.now.to_i)
            @cache_hits += 1
            return adjust_cached_trip_times(cached_result[:next_trips])
        end
        @cache_misses += 1

        xresult = fetch "GetNextTripsForStop", "stopNo=#{stop}&routeNo=#{route_no}"

        result = {
            stop: get_value(xresult, "t:StopNo"),
            stop_description: get_value(xresult, "t:StopLabel"),
            time: Time.now,
            routes: []
        }

        found_data = false

        xresult.xpath('t:Route/t:RouteDirection', OCT_NS).each do |route|
            get_error(route, "Error for route: #{route_no}")

            route_obj = {
                cached: false,
                route: get_value(route, "t:RouteNo"),
                route_label: get_value(route, "t:RouteLabel"),
                direction: get_value(route, "t:Direction"),
                request_processing_time: Time.parse(get_value(route, "t:RequestProcessingTime")),
                trips: []
            }
            route.xpath('t:Trips/t:Trip', OCT_NS).each do |trip|
                route_obj[:trips].push({
                    destination: get_value(trip, "t:TripDestination"), # e.g. "Barhaven"
                    start_time: get_value(trip, "t:TripStartTime"), # e.g. "14:25" TODO: parse to time
                    adjusted_schedule_time: get_value(trip, "t:AdjustedScheduleTime").to_i, # Adjusted schedule time in minutes
                    adjustment_age: get_value(trip, "t:AdjustmentAge").to_f, # Time since schedule was adjusted in minutes
                    last_trip: (get_value(trip, "t:LastTripOfSchedule") == "true"),
                    bus_type: get_value(trip, "t:BusType"),
                    gps_speed: get_value(trip, "t:GPSSpeed").to_f,
                    latitude: get_value(trip, "t:Latitude").to_f,
                    longitude: get_value(trip, "t:Longitude").to_f
                })
            end

            if route_obj[:trips].length != 0
                # Assume that if any trips are filled in, then all the trips will be filled in?
                # Is this a safe assumption?
                found_data = true
            end

            result[:routes].push route_obj
        end

        # Sometimes OC Transpo doesn't return any data for a route, even though it should.  When
        # this happens, if we have cached data, we use that, even if it's slightly stale.
        if !found_data and !cached_result.nil? and (get_trip_count(cached_result[:next_trips]) > 0)
            # Use the cached data, even if it's stale
            result = adjust_cached_trip_times(cached_result[:next_trips])
        else
            @next_trips_cache[cache_key] = {
                next_trips: result,
                time: Time.now.to_i
            }
        end


        return result
    end

    # Returns an array of
    # `{stop, stop_description, route_no, route_label, direction, arrival_in_minutes, ...}` objects.
    #
    # `...` is any data that would be available from a `trip` object from
    # `get_next_trips_for_stop()` (e.g. gps_speed, latitude, longitude, etc...)  Returned results
    # are sorted in ascending arrival time.
    #
    # Arguments:
    #     stop: (String) The stop number.
    #     route_nos: ([String]) can be a single route number, or an array of route numbers, or nil.
    #         If nil, then this method will call get_route_summary_for_stop to get a list of routes.
    #     route_label: (String) If "route_label" is supplied, then only trips with a matching
    #         route_label will be returned.
    #
    def simple_get_next_trips_for_stop(stop, route_nos=nil, route_label=nil)
        answer = []
        if route_nos.nil?
            route_summary = get_route_summary_for_stop(stop)
            route_nos = route_summary[:routes].map { |e| e[:route] }

        elsif !route_nos.kind_of?(Array)
            route_nos = [route_nos] end

        route_nos.uniq.each do |route_no|
            oct_result = get_next_trips_for_stop stop, route_no
            oct_result[:routes].each do |route|
                if route_label.nil? or (route[:route_label] == route_label)
                    route[:trips].each do |trip|
                        answer.push(trip.merge({
                            stop: oct_result[:stop],
                            stop_description: oct_result[:stop_description],
                            route_no: route[:route],
                            route_label: route[:route_label],
                            direction: route[:direction],
                            arrival_in_minutes: trip[:adjusted_schedule_time],
                            live: (trip[:adjustment_age] > 0)
                        }))
                    end
                end
            end
        end

        answer.sort! { |a,b| a[:arrival_in_minutes] <=> b[:arrival_in_minutes] }

        return answer
    end

    private

    BASE_URL = "https://api.octranspo1.com/v1.1"
    OCT_NS = {'oct' => 'http://octranspo.com', 't' => 'http://tempuri.org/'}
    NEXT_TRIPS_CACHE_SIZE = 100
    ROUTE_CACHE_SIZE = 100

    # Fetch and parse some data from the OC-Transpo API.  Returns a nokogiri object for
    # the Result within the XML document.
    def fetch(resource, params)
        @api_calls = (@api_calls + 1)
        response = RestClient.post("#{BASE_URL}/#{resource}",
            "appID=#{@app_id}&apiKey=#{@app_key}&#{params}")

        doc = Nokogiri::XML(response.body)
        xresult = doc.xpath("//oct:#{resource}Result", OCT_NS)
        if xresult.length == 0
            raise "Error: No reply for #{resource}"
        end

        get_error(xresult, "Error for #{params}:")

        return xresult
    end

    # Count the number of trips in a result from OC Transpo
    def get_trip_count(routes)
        answer = 0
        if !routes.nil?
            routes[:routes].each do |route|
                answer += route[:trips].length
            end
        end

        return answer
    end

    # Return a single child from a nokogiri document.
    def get_child(node, el)
        return node.at_xpath(el, OCT_NS)
    end

    # Return the value of a child from a nokogiri document.
    def get_value(node, el)
        child = node.at_xpath(el, OCT_NS)
        if child.nil? then raise "Could not find child element #{el}" end
        return child.content
    end

    # Fetch an OC-Transpo "Error" from a node.
    def get_error(node, message="")
        xerror = get_child(node, "t:Error")
        if (!xerror.nil? and !xerror.content.empty?)
            error = xerror.content
            error = case error
                when "1"
                    "Invalid API key"
                when "2"
                    "Unable to query data source"
                when "10"
                    "Invalid stop number"
                when "11"
                    "Invalid route number"
                when "12"
                    "Stop does not service route"
                else
                    error
            end
            raise "#{message}: #{error}"
        end
    end

    def deep_copy(o)
        Marshal.load(Marshal.dump(o))
    end

    # When returning cached trips, we need to adjust the `:adjustment_age` and
    # `:adjusted_schedule_time` of each entry to reflect how long the object has been
    # sitting in the cache.
    def adjust_cached_trip_times(cached_routes)

        cached_routes = deep_copy cached_routes
        cached_routes[:cached] = true

        time_delta = Time.now.to_i - cached_routes[:time].to_i
        cached_routes[:routes].each do |route_obj|
            route_obj[:trips].each do |trip|
                trip[:adjusted_schedule_time] -= (time_delta.to_f / 60).round
                if trip[:adjustment_age] > 0
                    trip[:adjustment_age] += time_delta.to_f / 60
                end
            end

            # Filter out results with negative arrival times, since they've probably
            # already gone by.
            route_obj[:trips].select! { |trip| trip[:adjusted_schedule_time] >= 0 }
        end

        return cached_routes
    end

end