module ChiNAS
using Toolips
using TOML
using ReplMaker
using Toolips.Components
import Base: in, getindex

DLS = Base.Downloads()

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
    secret::String
end

mutable struct NASCommand{T <: Any} end

function in(vec::Vector{NASUser}, name::String)
    f = findfirst(user -> user.ip == name, vec)
    ~(isnothing(f))::Bool
end

function getindex(vec::Vector{NASUser}, name::String)
    f = findfirst(user -> user.ip == name, vec)
    vec[f]::NASUser
end

# extensions
logger = Toolips.Logger()

MANAGER = NASManager("", "", Vector{AbstractRepository}(), Vector{NASUser}(), "testpass")

function host(ip::String, port::Int64; path::String = pwd(), hostname::String = "chiNAS")
    # read the path, make config, build the routes
    path = replace(path, "\\" => "/")
    MANAGER.home_dir = path * "/" * "home/"
    dir_read::Vector{String} = readdir(path)
    if ~("config.toml" in dir_read)
        config_path::String = path * "/config.toml"
        touch(config_path)
        basic_dct = Dict("users" => Dict("admin" => Dict("ip" => "", "wd" => "~/")))
        open(config_path, "w") do o::IO
            TOML.print(o, basic_dct)
        end
    end
    config = TOML.parse(read(path * "/config.toml", String))
    # get user and repo data
    MANAGER.users = [begin
        info = config["users"][user]
        NASUser(info["ip"], user, info["wd"])
    end for user in keys(config["users"])]
    # start the server, add the routes
    start!(ChiNAS, ip:port)
    # key
    secret::String = Toolips.gen_ref(5)
    secret_path::String = path * "/secret.txt"
    if ~("secret.txt" in dir_read)
        touch(secret_path)
    else
        secret = read(secret_path, String)
    end
    open(path * "/secret.txt", "w") do o::IOStream
        write(o, secret)
    end
    println("secret key: ", secret)
    MANAGER.secret = secret
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
            println(third_response)
            print("failure. name taken? for now we give up here.")
            return
        end
        return(connect(ip, port, path = path))
    end
    # regular connection
    global CONNECTED = ip:port
    initrepl(send_to_connected,
                prompt_text="$(ip):$(port) >",
                prompt_color=:cyan,
                start_key="-",
                mode_name="Remote Filesystem")
end

function send_to_connected(line::String)
    split_cmd::Vector{SubString} = split(line, " ")
    if split_cmd[1] == "download"
        download_url = Toolips.post("http://$(CONNECTED.ip):$(CONNECTED.port)", "download;$(split_cmd[2])")
        path = pwd()
        if length(split_cmd) > 2
            path = split_cmd[3]
        end
        DLS.download("http://$(CONNECTED.ip):$(CONNECTED.port)" * download_url, path * "/$(split_cmd[2])")
        return
    end
    response = Toolips.post("http://$(CONNECTED.ip):$(CONNECTED.port)", replace(line, " " => ";"))
    println(replace(response, ";" => "\n"))
end

# routing
main = route("/") do c::Toolips.AbstractConnection
    args = get_args(c)
    client_ip::String = get_ip(c)
    if :secret in keys(args)
        if args[:secret] == MANAGER.secret
            new_user = NASUser(client_ip, "", "~/")
            push!(MANAGER.users, new_user)
            write!(c, "success")
            return
        end
        write!(c, "denied")
        return
    elseif :name in keys(args)
        name::String = args[:name]
        f = findfirst(user -> user.name == name, MANAGER.users)
        if isnothing(f)
            MANAGER.users[client_ip].name = name
        else
            MANAGER.users[f].ip = client_ip
        end
        write!(c, "success")
        return
    end
    ips = [user.ip for user in MANAGER.users]
    if ~(client_ip in ips)
        write!(c, "secret?")
        return
    end
    user = MANAGER.users[client_ip]
    request = get_post(c)
    command_split = split(request, ";")
    f = findfirst(";", request)
    if length(command_split) == 1 || isnothing(f) || command_split[1] == "ls"
        current_dir_files = readdir(replace(user.wd, "~/" => MANAGER.home_dir * "/"))
        if length(current_dir_files) == 0
            write!(c, "no files found in this directory")
            return
        end
        write!(c, join([filename for filename in current_dir_files], ";"))
        return
    end
    write!(c, 
    do_command(user, NASCommand{Symbol(command_split[1])}(), 
    command_split[2:length(command_split)] ...))
end


function do_command(user::NASUser, command::NASCommand{:cd}, args::SubString ...)
    selected::String = string(args[1])
    if selected == ".."
        if user.wd != "~/"
            wdsplit = split(user.wd, "/")
            if length(wdsplit) > 2
                user.wd = join(wdsplit[1:length(wdsplit) - 2], "/") * "/"
            else
                user.wd = "~/"
            end
        else
            println(user.wd)
        end
        return(user.wd)::String
    end
    current_dir_files = readdir(replace(user.wd, "~/" => MANAGER.home_dir * "/"))
    if ~(selected in current_dir_files)
        return("ERROR: Directory does not exist to change into.")
    end
    user.wd = user.wd * selected * "/"
    user.wd::String
end

function do_command(user::NASUser, command::NASCommand{:mkdir}, args::SubString ...)
    mkdir(replace(user.wd, "~/" => MANAGER.home_dir * "/") * args[1])
    return("made directory: $(user.wd * args[1])")
end

function do_command(user::NASUser, command::NASCommand{:rmdir}, args::SubString ...)
    rmdir(replace(user.wd, "~/" => MANAGER.home_dir * "/") * args[1])
    return("removed directory: $(user.wd * args[1])")
end

function do_command(user::NASUser, command::NASCommand{:rm}, args::SubString ...)
    rm(replace(user.wd, "~/" => MANAGER.home_dir * "/") * args[1])
    return("removed file: $(user.wd * args[1])")
end

function do_command(user::NASUser, command::NASCommand{:touch}, args::SubString ...)
    touch(replace(user.wd, "~/" => MANAGER.home_dir * "/") * args[1])
    return("created file: $(user.wd * args[1])")
end

function do_command(user::NASUser, command::NASCommand{:download}, args::SubString ...)
    route_path::String = "/" * Toolips.gen_ref(5)
    new_r = route(route_path) do c::AbstractConnection
        write!(c, read(replace(user.wd, "~/" => MANAGER.home_dir * "/") * args[1], String))
        f = findfirst(r -> r.path == route_path, c.routes)
        deleteat!(c.routes, f)
    end
    push!(ChiNAS.routes, new_r)
    return(route_path)::String
end

# make sure to export!
export main, default_404, logger, MANAGER
end # - module ChiNAS <3