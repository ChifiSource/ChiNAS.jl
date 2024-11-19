module ChiNAS
using Toolips
using TOML
using ReplMaker
using Toolips.Components
import Base: in, getindex

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
    f = findfirst(name -> name == user.ip, vec)
    ~(isnothing(f))::Bool
end

function getindex(vec::Vector{NASUser}, name::String)
    f = findfirst(name -> name == user.ip, vec)
    vec[f]::NASUser
end

# extensions
logger = Toolips.Logger()

MANAGER = NASManager("", "", Vector{AbstractRepository}(), Vector{NASUser}(), "testpass")

function host(ip::String, port::Int64; path::String = pwd(), hostname::String = "chiNAS")
    # read the path, make config, build the routes
    path = replace(path, "\\" => "/")
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
    println("ChiNAS is now active!")
    # key
    secret::String = Toolips.gen_ref(5)
    secret_path::String = path * "/secret.txt"
    println("secret key: ", secret)
    if ~("secret.txt" in dir_read)
        touch(secret_path)
    else
        secret = read(secret_path, String)
    end
    open(path * "/secret.txt", "w") do o::IOStream
        write(o, secret)
    end
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

function send_to_connected(line::String)
    split_cmd::Vector{SubString} = split(line, " ")
    if split_cmd[1] == "download"
        download_url = Toolips.post(CONNECTED, "DOWNLOAD:$(split_cmd[2])")
        return
    end
    response = Toolips.post(CONNECTED, replace(line, " " => ";"))
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
            write!(c, "confirmed")
            return
        end
        write!(c, "denied")
    elseif :name in keys(args) && client_ip in MANAGER.users
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
        current_dir_files = readdir(replace(user.wd, "~/" => NASManager.home_dir * "/"))
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
            user.wd = join(wdsplit[1:length(wdsplit) - 1], "/")
        end
    end
    current_dir_files = readdir(replace(user.wd, "~/" => NASManager.home_dir * "/"))
    if ~(selected in current_dir_files)
        return("ERROR: Directory does not exist to change into.")
    end
    user.wd = user.wd * selected * "/"
end


# make sure to export!
export main, default_404, logger, MANAGER
end # - module ChiNAS <3