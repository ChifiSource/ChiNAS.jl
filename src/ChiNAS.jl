module ChiNAS
using Toolips
using TOML
using REPLMaker
using Toolips.Components

CONNECTED = "":0

# types
abstract type AbstractRepository end

mutable struct Repository <: AbstractRepository
    uri::String
    file_count::Int64
end

mutable struct NASUser
    ip::String
    name::String
    wd::String
end

mutable struct NASManager <: Toolips.AbstractExtension
    hostname::String
    home_dir::String
    repos::Vector{AbstractRepository}
    users::Vector{NASUser}
end

# extensions
logger = Toolips.Logger()

MANAGER = NASManager("", "", Vector{AbstractRepository}(), Vector{NASUser}())

function host(ip::String, port::Int64; path::String = pwd(), hostname::String = "chiNAS")
    # read the path, make config, build the routes
    path = replace(path, "\\" => "/")
    dir_read::Vector{String} = readdir(path)
    if ~("config.toml" in dir_read)
        config_path::String = path * "/config.toml"
        touch(config_path)
        open(config_path, "w") do o::IO
            
        end
    else

    end
    config = TOML.parse(read(path * "/config.toml", String))
    [begin
        
    end for user in config["users"]]
    if ~("secret.txt" in dir_read)
        touch(path * "/secret.txt")
    end
    file_routes = mount(path)
    # start the server, add the routes
    start!(ChiNAS, ip:port)
    ChiNAS.routes = vcat(ChiNAS.routes, file_routes ...)
    println("ChiNAS is now active!")
    # key
    secret::String = gen_ref(5)
    println("secret key: ", secret)
end

function connect(ip::String, port::Int64; path::String = pwd())
    init_response::String = Toolips.get(ip:port)
    if init_response == "secret?"
        println("This storage requires a password to access.")
        println("Please enter the access password:")
        pwd = readline()
        second_response = Toolips.get("http://$ip:$port/?secret=$pwd")
        if second_response == "denied"
            println("Access denied, it seems the password has been entered wrong.")
            return(connect(ip, port, path = path))
        end
        println("Select a user-name from which to access this remote file-system:")
        name = readline()
        third_response = Toolips.get("http://$ip:$port/?name=$name")
        if ~(third_response == "success")
            print("failure. name taken? for now we give up here.")
            return
        end
        return(connect(ip, port, path = path))
    end
    # regular connection
    server_name = Toolips.get("http://$ip:$port/hostname")
    CONNECTED = ip:port
    interpret_file_response(init_response)
    initrepl(send_to_connected,
                prompt_text="$server_name >",
                prompt_color=:lightblue,
                start_key="-",
                mode_name="Remote Filesystem")
end

function interpret_file_response()

end

function send_to_connected()

end

# routing
main = route("/") do c::Toolips.AbstractConnection
    args = get_args(c)
    if :secret in keys(args)
        if args[:secret] == MANAGER.secret
            new_user = NASUser(get_ip(c), "", "~/")
            push!(MANAGER.users, new_user)
            write!(c, "confirmed")
            return
        end
        write!(c, "denied")
    elseif :name in args
        MANAGER.users[get_ip(c)].name = args[name]
        write!(c, "success")
    end
    client_ip::String = get_ip(c)
    ips = [user.ip for user in MANAGER.users]
    if ~(client_ip in ips)
        write!(c, "secret?")
        return
    end
    user = MANAGER.users[client_ip]
    response = ""
    [begin

    end for active_file in readdir(replace(user.wd))]
end

# folder:example:144
# .csv:doit.csv:144

# make sure to export!
export main, default_404, logger, MANAGER
end # - module ChiNAS <3