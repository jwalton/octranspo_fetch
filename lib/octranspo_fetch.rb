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
        @trips_cache = LruRedux::Cache.new(TRIPS_CACHE_SIZE)
        @route_summary_cache = LruRedux::Cache.new(ROUTE_CACHE_SIZE)
        @api_calls = 0
    end

    def clear_cache()
        @trips_cache.clear()
        @route_summary_cache.clear()
    end

    # Returns the number of API calls made by this instance since it was created.
    def requests()
        return @api_calls
    end

    # Get a list of routes for a specific stop.
    #
    # Returns a {stop, stop_description, routes: [{route, direction_id, direction, heading}]} object.
    # Note that route data is cached.
    #
    # Arguments:
    #     stop: (String) The stop number.
    #
    def get_route_summary_for_stop(stop)
        cached_result = @route_summary_cache[stop]
        if !cached_result.nil? then return cached_result end

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

        @route_summary_cache[stop] = result

        return result
    end

    # Get the next three trips for the given stop.  Note this may return data for the same route
    # number in multiple headings.
    #
    # Arguments:
    #     stop: (String) The stop number.
    #     route_no: (String) The route number.
    #
    def get_next_trips_for_stop(stop, route_no)
        xresult = fetch "GetNextTripsForStop", "stopNo=#{stop}&routeNo=#{route_no}"

        result = {
            stop: get_value(xresult, "t:StopNo"),
            stop_description: get_value(xresult, "t:StopLabel"),
            routes: []
        }

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

            cache_key = "#{stop}-#{route_obj[:route]}-#{route_obj[:direction]}"
            if route_obj[:trips].length == 0
                # Sometimes OC Transpo doesn't return any data.  When this happens, fetch data from the cache.
                trips = @trips_cache[cache_key]
                if !trips.nil?
                    time_delta = Time.now.to_i - trips[:time]
                    route_obj[:request_processing_time] += time_delta
                    route_obj[:trips] = deep_copy(trips[:trips])
                    route_obj[:trips].each do |trip|
                    route_obj[:cached] = true
                        trip[:adjusted_schedule_time] += (time_delta.to_f / 60).round
                        if trip[:adjustment_age] > 0
                            trip[:adjustment_age] += time_delta.to_f / 60
                        end
                    end

                else
                    # No data in the cache... Hrm...
                end

            else
                # Cache the trips for later
                @trips_cache[cache_key] = {
                    time: Time.now.to_i,
                    trips: route_obj[:trips]
                }
            end

            result[:routes].push route_obj
        end


        return result
    end

    # Returns an array of
    # `{stop, stop_description, route_no, route_label, direction, arrival_in_minutes, ...}` objects.
    #
    # `...` is any data that would be available from a `trip` object from
    # `get_next_trips_for_stop()` (e.g. gps_speed, latitude, longitude, etc...)
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
    TRIPS_CACHE_SIZE = 100
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
end

