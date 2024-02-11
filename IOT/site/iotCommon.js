// default definition of is_server

var is_server = 0;


// prh - might be useful to have a watchdog that reloads the page every so often

const debug_alive = 1;
    // these javascript timers are about 1.6 times faster than advertised on my lenovo with firefox
    // they are tuned to myIOTserver not timing out (it listens)
const keep_alive_interval = 15000;      // how often to check keep alive
const keep_alive_timeout = 5000;        // how long to wait for ping response before considering it dead
const ws_repoen_delay = 3000;           // how long to wait for re-open (allowing for close) after dead

// constants that agree with C++ code

const VALUE_TYPE_COMMAND = 'X';         // monadic (commands)
const VALUE_TYPE_BOOL    = 'B';        // a boolean (0 or 1)
const VALUE_TYPE_CHAR    = 'C';        // a single character
const VALUE_TYPE_STRING  = 'S';        // a string
const VALUE_TYPE_INT     = 'I';        // a signed 32 bit integer
const VALUE_TYPE_FLOAT   = 'F';        // a float
const VALUE_TYPE_TIME    = 'T'         // time stored as 32 bit unsigned integer; string in UI
const VALUE_TYPE_ENUM    = 'E';        // a enumerated integer

const VALUE_STORE_PROG     = 0x00;      // only in ESP32 memory
const VALUE_STORE_NVS      = 0x01;      // stored/retrieved from NVS
const VALUE_STORE_WS       = 0x02;      // broadcast to / received from WebSockets
const VALUE_STORE_MQTT_PUB = 0x04;      // published/subscribed to on (the) MQTT broker
const VALUE_STORE_MQTT_SUB = 0x08;      // published/subscribed to on (the) MQTT broker
const VALUE_STORE_DATA     = 0x10;      // history stored/retrieved from SD database
const VALUE_STORE_SERIAL   = 0x40;

const VALUE_STORE_PREF     = (VALUE_STORE_NVS | VALUE_STORE_WS);
const VALUE_STORE_TOPIC    = (VALUE_STORE_MQTT_PUB | VALUE_STORE_MQTT_SUB);

const VALUE_STYLE_NONE       = 0x0000;      // no special styling
const VALUE_STYLE_READONLY   = 0x0001;      // Value may not be modified
const VALUE_STYLE_REQUIRED   = 0x0002;      // String item may not be blank
const VALUE_STYLE_PASSWORD   = 0x0004;      // displayed as '********', protected in debugging, etc. Gets "retype" dialog in UI
const VALUE_STYLE_TIME_SINCE = 0x0008       // ui shows '23 minutes ago' in addition to the time string
const VALUE_STYLE_VERIFY     = 0x0010;      // UI buttons will display a confirm dialog
const VALUE_STYLE_LONG       = 0x0020;      // UI will show a long (rather than default 15ish) String Input Control
const VALUE_STYLE_OFF_ZERO   = 0x0040;      // Allows 0 below min and displays it as "OFF"
const VALUE_STYLE_RETAIN     = 0x0100;      // MQTT if published, will be "retained"


// program vars

var fake_uuid;
var web_socket;
var ws_connect_count = 0;
var ws_open_count = 0;
var device_name = '';
var device_uuid = '';
var device_has_sd = 0;
var device_list;
var file_request_num = 0;
var cur_button = 'dashboard_button';
var alive_timer;


function onTab(event)
    // triggered when the user changes tabs in the UI
{
    cur_button = event.target.id;
}


//--------------------------------
// display utilities
//--------------------------------


function myAlert(msg)
    // cant use alert() cuz it blocks the keep alive stuff
{
    $('#alert_msg').html(msg);
    $('#alert_dlg').modal('show');

    // setTimeout(function() { alert(msg); }, 1);
}

function fileKB(i)
{
    var rslt;

    if (i > 1000000000)
    {
        i /= 1000000000;
        rslt = i.toFixed(2) + " GB";
    }
    else if (i > 1000000)
    {
        i /= 1000000;
        rslt = i.toFixed(2) + " MB";
    }
    else if (i > 1000)
    {
        i /= 1000;
        rslt = i.toFixed(2) + " KB";
    }
    else
    {
        rslt = i;
    }
    return rslt;
}


function pad(num, size) {
    var num = num.toString();
    while (num.length < size) num = "0" + num;
    return num;
}


function formatSince(tm)
{
    if (tm == 0)
        return '';
    const now = new Date()
    const myMilllisecondsSinceEpoch = now.getTime();   //  + (now.getTimezoneOffset() * 60 * 1000)
    const mySecondsSinceEpoch = Math.round(myMilllisecondsSinceEpoch / 1000)

    var secs = mySecondsSinceEpoch - tm;
    if (secs <= 0)
        return '';

    var hours = parseInt(secs / 3600);
    secs -= hours * 3600;
    var mins = parseInt(secs / 60);
    secs -= mins * 60;
    return pad(hours,2) + ':' + pad(mins,2) + ':' + pad(secs,2);
}



//------------------------------------------------
// HTTP File Uploader
//------------------------------------------------

function uploadFiles(evt)
{
    var obj = evt.target;
    var id = obj.id;
    var files = obj.files;

    var args = "";
    var total_bytes = 0;
    var formData = new FormData();
    for (var i=0; i<files.length; i++)
    {
        formData.append("uploads", files[i]);
            // it does not matter what the formdata object is named,
            // ANY file entries in the post data are treated as file uploads
            // by the ESP32 WebServer

        // pass the filesizes as an URL argument,

        if (args == "")
            args += "?";
        else
            args += "&";
        args += files[i].name + "_size=" + files[i].size;
        total_bytes += files[i].size;
    }

    args += "&num_files=" + files.length;
    args += "&file_request_id=" + fake_uuid + file_request_num++;

    var xhr = new XMLHttpRequest();
    xhr.timeout = 30000;

    // completion and errors are handled by websocket with upload_filename in it
    // the file list is broadcast automatically by the HTTP
    // server upon the completion (or failure) of any file uploads.
    // so we don't use these js functions:
    //      xhr.onload = function () {};
    //      xhr.onerror = function () {};
    //          we sometimes get http errors even though everything worked
    //      xhr.ontimeout = function () { alert("timeout uploading"); };
    //          we sometimes get timeout errors even though the server succeeded

    if (id == 'ota_files' || files.length > 2 || total_bytes > 10000)
    {
        $('#upload_filename').html(files[0].name);
        $('#upload_progress_dlg').modal('show');    // {show:true});
        $("#upload_progress").css("width", "0%");
        $('#upload_pct').html("0%");
        $('#upload_num_files').html(files.length);
    }

    xhr.open("POST", "/" + id  + args, true);

    // add the uuid header for pass through by the myIOTServer.pm

    if (device_uuid)
        xhr.setRequestHeader('x-myiot-deviceuuid',device_uuid);
    xhr.send(formData);
}



//--------------------------------------
// web_socket
//--------------------------------------


function sendCommand(command,params)
{
    var obj = params ? params : {};
    obj["cmd"] = command;
    var cmd = JSON.stringify(obj);
    if (debug_alive || !command.includes("ping"))
        console.log("sendCommand(" + command + ")=" + cmd);
    web_socket.send(cmd);
}


function checkAlive()
{
    if (!web_socket || web_socket.opening || web_socket.closing)
        return;
    if (debug_alive)
        console.log("checkAlive web_socket(" + web_socket.my_id + ")");

    if (!web_socket.alive)
    {
        ws_closing = 1;
        if (debug_alive)
            console.log("checkAlive closing web_socket(" + web_socket.my_id + ")");
        $('#ws_status2').html("WS(" + web_socket.my_id + ") CLOSING");
        web_socket.close();
        if (debug_alive)
            console.log("checkAlive calling openWebSocket()");
        openWebSocket();
    }
    else
    {
        if (debug_alive)
            console.log("checkAlive(" + web_socket.my_id + ") ok");
        clearTimeout(alive_timer);
        alive_timer = setTimeout(keepAlive,keep_alive_interval);
    }

}

function keepAlive()
{
    if (!web_socket || !web_socket.alive || web_socket.opening || web_socket.closing)
        return;
    if (debug_alive)
        console.log("keepAlive web_socket(" + web_socket.my_id + ")");
    web_socket.alive = 0;
    sendCommand("ping");
    clearTimeout(alive_timer);
    alive_timer = setTimeout(checkAlive,keep_alive_timeout);
}



// var old_socket;
    // we keep the old one around so it is not garbage collected during close cycle

function openWebSocket()
{
    // disable all controls=

    $('.myiot').attr("disabled",1);

    // is_server connects to HTTPS Server port using
    // WSS at the url /ws, or HTTP Server at 8080

    var url;
    if (is_server)
    {
        if (location.port == '8080')    // specific HTTP port
            url = 'ws://' + location.host + "/ws";
        else
            url = 'wss://' + location.host + "/ws";
    }

    // !is_server uses HTTP to location.port + 1, or 81 by default

    else
    {
        // allow for extracting the port+1 from ports other than default 80
        var port = location.port;
        if (port == '')
            port = '80';
        url = 'ws://' + location.hostname + ':' + (parseInt(port) + 1);
    }

    console.log("openWebSocket(" + ws_connect_count  + ") to " + url);
    $('#ws_status1').html("WS(" + ws_connect_count + ") O " + url);

    // old_socket = web_socket;
    ws_open_count++;

    web_socket = new WebSocket(url);
    web_socket.my_id = ws_connect_count++;
    web_socket.opening = 1;
    web_socket.closing = 0;
    web_socket.alive = 0;

    web_socket.onopen = function(event)
    {
        console.log("web_socket(" + this.my_id + ") OPENED");
        $('#ws_status1').html("WS(" + this.my_id + ") OPENED");

        this.opening = 0;

        if (is_server)
        {
            sendCommand("device_list");
        }
        else
        {
            // we specifically do the value_list AFTER the device_info
            // so that upon value_list we can change-away-from-the-sdcard-tab
            // if there is no SD card

            sendCommand("device_info");
            sendCommand("value_list");
            sendCommand("spiffs_list");
            sendCommand("sdcard_list");
        }
        this.alive = 1;
        clearTimeout(alive_timer);
        alive_timer = setTimeout(keepAlive,keep_alive_interval);

        // sendCommand("get_chart_data");
    };

    web_socket.onclose = function(closeEvent)
    {
        ws_open_count--;

        console.log("web_socket(" + this.my_id +") CLOSED");
        $('#ws_status2').html("WS(" + this.my_id + ") CLOSED");

        this.alive = 0;
        this.opening = 0;
        this.closing = 0;

        if (!ws_open_count)
        {
            if (debug_alive)
                console.log("websocket.onclose setting delayed call to openWebSocket")
            clearTimeout(alive_timer);
            alive_timer = setTimeout(openWebSocket,ws_repoen_delay);
        }
    };

    web_socket.onmessage = handleWS;
}




//---------------------------------------------
// WEB SOCKET COMMAND HANDLER
//---------------------------------------------

function handleWS(ws_event)
{
    var ws_msg = ws_event.data;
    var obj = JSON.parse(ws_msg);
    if (!obj)
        return;

    if (obj.error)
        myAlert("ERROR: " + obj.error);
    if (obj.pong)
    {
        web_socket.alive = 1;
        if (debug_alive) console.log("WS:pong");
    }

    if (obj.set)
    {
        // from the device to 'set' a value
        // obj.set is the 'id' to set.

        $('.' + obj.set).each(function () {
            var ele = $(this);

            // set new value into 'time since' data-value

            var data_value = ele.attr('data-value');
            if (typeof(data_value) != 'undefined')
                ele.attr({'data-value' : obj.value});

            // set the value based on the value type

            if (ele.is("span"))
                ele.html(obj.value)
            else if (ele.hasClass("my_switch"))
                ele.prop("checked",obj.value);
            else
                ele.val(obj.value);
        });

        // The DEVICE_BOOTING value is ONLY sent upon rebooting
        // so we disable all controls here (and show the word)

        if (obj.set == 'DEVICE_BOOTING')
        {
            $('.myiot').attr("disabled",1);
            $('#device_status').html('rebooting');
        }
    }

    // device_name is part of device_info, and also used to note the UUID
    // and whether the SD card button should be shown

    if (obj.device_name)
    {
        device_name = obj.device_name;
        device_uuid = obj.uuid;
        console.log("device_name=" + device_name + " device_uuid=$uuid");
        if (!is_server)
            document.title = device_name;
        $('#DEVICE_NAME').html(device_name);
        device_has_sd = parseInt(obj.has_sd);
            // cache the value of the has_sd for use in
            // value_list fillTables() method.
    }

    // if there are values, then we fill the tables
    // this is essentially the 'new' context trigger

    if (obj.values)
        fillTables(obj);

    // update SPIFFS or SDCARD file lists

    if (obj.spiffs_list)
        updateFileList(obj.spiffs_list);
    if (obj.sdcard_list)
        updateFileList(obj.sdcard_list);

    // upload progress dialog
    // only does antying if this user happens to have
    // opened the dialog ...

    if (obj.upload_filename)
    {
        var pct = obj.upload_progress;
        $('#upload_pct').html(obj.upload_progress + "%");
        $('#upload_filename').html(obj.upload_filename);
        $("#upload_progress").css("width", obj.upload_progress + "%");
        if (pct >= 100)
        {
            $('#upload_progress_dlg').modal('hide');
            in_upload = false;
        }
        if (obj.upload_error)
            myAlert("There was a server error while uploading");
    }

    //--------------------------
    // server specific
    //--------------------------
    // disable or enable controls if ws_open is 0 or 1

    if (typeof obj.ws_open != 'undefined')
    {
        var cur = $('#device_status').html();
        cur = cur.startsWith('rebooting') ? 'rebooting ' : '';
        cur += obj.ws_open ? 'ws_open' : 'ws_closed';
        $('#device_status').html(cur);
        if (obj.ws_open)
            $('.myiot').removeAttr("disabled");
        else
            $('.myiot').attr("disabled",1);
    }

    // build the device list, pick the 0th one by default

    if (obj.device_list)
    {
        console.log("device_list=" + ws_msg);
        device_list = obj.device_list;
        var the_list = $('#device_list');
        the_list.empty();

        for (var i=0; i<device_list.length; i++)
        {
            var device = device_list[i];
            if (i == 0)
            {
                device_name = device.name;
                device_uuid = device.uuid;
            }
            var option = $("<option>").attr('value',device.uuid).text(device.name);
            the_list.append(option);
        }

        // activate the default device ...

        if (device_uuid)
        {
            the_list.val(device_uuid);
            sendCommand("set_context",{uuid:device_uuid});
        }
    }
}




//---------------------------------------
// file table filler
//---------------------------------------

function updateFileList(obj)
{
    var prefix = obj.sdcard ? "sdcard" : "spiffs";

    $('table#' + prefix + '_list tbody').empty();
    $('#' + prefix + '_used').html(fileKB(obj.used) + " used");
    $('#' + prefix + '_size').html("of " + fileKB(obj.total) + " total");

    // note that file links, which open in another tab,
    // are NOT disabled during reboot/ws_close events,
    // BUT, they WILL fail in the server if the device
    // WS is closed.

    for (var i=0; i<obj.files.length; i++)
    {
        var file = obj.files[i];
        var link = '<a class="myiot" ' +
            'target=”_blank” ' +
            'href="/' + prefix + '/' + file.name;
        if (is_server)
            link += '?uuid=' + device_uuid;
        link += '">' + file.name;
        link += '</a>';
        var button = "<button " +
            "class='btn btn-secondary myiot' " +
            // "class='my_trash_can' " +
            "onclick='confirmDelete(\"/" + prefix + "/" +  file.name + "\")'>" +
            "delete" +
            // "<span class='my_trash_can'>delete</span>" +
            "</button>";
        $('table#' + prefix + '_list tbody').append(
            $('<tr />').append(
              $('<td />').append(link),
              $('<td />').text(file.size),
              $('<td />').append(button) ));
    }
}




//---------------------------------------
// UI Builder
//---------------------------------------

function addSelect(item)
{
    var input = $('<select>')
        .addClass(item.id)
        .addClass('myiot')
        .attr({
            name : item.id,
            onchange : 'onValueChange(event)',
            'data-type' : item.type,
            'data-value' : item.value
        });

    var options = item.allowed.split(",");
    for (var i=0; i<options.length; i++)
        input.append($("<option>").attr('value',options[i]).text(options[i]));
    input.val(item.value);
    return input;
}


function addInput(item)
    // inputs know their 'name' is equal to the item.id
{
    var is_bool = item.type == VALUE_TYPE_BOOL;
    var is_number =
        is_bool ||
        item.type == VALUE_TYPE_INT ||
        item.type == VALUE_TYPE_FLOAT;
    var input_type =
        (item.style & VALUE_STYLE_PASSWORD) ? 'password' :
        is_number ? "number" :   //  && !(item.style & VALUE_STYLE_OFF_ZERO) ? 'number' :
        'text'

    // My modified spinner renders 0 as off for those with class "off_zero"
    // So we go ahead and morph the value "off" to zero here.
    // Without the modified spinner "off" is not supported anyways (but 0 works consistently)

    if (item.style & VALUE_STYLE_OFF_ZERO && item.value == "off")
        item.value = 0;

    var input = $('<input>')
        .addClass(item.id)
        .addClass('myiot')
        .attr({
            name : item.id,
            type : input_type,
            value : item.value,
            onchange : 'onValueChange(event)',
            'data-type' : item.type,
            'data-value' : item.value,
            'data-style' : item.style,
            'data-min' : item.min,
        });

    // for OFF_ZERO we set the min to zero, skip during incs/decs,
    // and enforce it via the data-min in our onchange

    var use_min = item.min;
    if (item.style & VALUE_STYLE_OFF_ZERO)
    {
        use_min = 0;
        input.addClass('off_zero');
    }
    if (item.style & VALUE_STYLE_LONG)
        input.attr({size:80});

    if (is_number)
        input.attr({
            min: is_bool ? 0 : use_min,
            max: is_bool ? 1 : item.max
        })
    if (item.type == VALUE_TYPE_FLOAT)
        input.attr({
            step : "0.001",
            'data-decimals' : 3 });
    return input;
}


function addSwitch(item)
{
    var input = $('<input />')
        .addClass(item.id)
        .addClass('myiot')
        .addClass('form-check-input')
        .addClass('my_switch')
        .attr({
            name: item.id,
            type: 'checkbox',
            onchange:'onSwitch(event)' });
    input.prop('checked',item.value);
    var ele = $('<div />')
        .addClass('form-check form-switch my_switch')
        .append(input);
    return ele;
}


function addOutput(item)
    // outputs are only colleced by class==item.id
{
    var obj = $('<span>').addClass(item.id)
    if (item.style & VALUE_STYLE_TIME_SINCE)
    {
        // the value is the time as an integer
        obj.addClass('time_since');
        obj.attr({'data-value' : item.value});
        obj.html(formatSince(item.value));
    }
    else
        obj.html(item.value);
    return obj;
}


function addButton(item)
{
    return $('<button />')
        .addClass('myiot')
        .attr({
            id: item.id,
            'data-verify' : (item.style & VALUE_STYLE_VERIFY ? true : false),
            onclick:'onButton(event)' })
        .html(item.id);
}


function addItem(tbody,item)
{
    var ele;

    if (item.type == VALUE_TYPE_COMMAND)
        ele = addButton(item);
    else if (item.style & VALUE_STYLE_READONLY)
        ele = addOutput(item);
    else if (item.type == VALUE_TYPE_BOOL)
        ele = addSwitch(item);
    else if (item.type == VALUE_TYPE_ENUM)
        ele = addSelect(item);
    else
        ele = addInput(item);

    tbody.append(
        $('<tr />').append(
            $('<td />').text(item.id),
            $('<td />').append(ele) ));
}


function fillTable(values,ids,tbody)
    // prh - should hide empty tabs
{
    tbody.empty();
    if (!ids)
        return;
    ids.forEach(function (id) {
        var item = values[id];
        if (item)
            addItem(tbody,item);
        else
            myAlert("Uknown item_id in fillTable " + tbody.id + ": " + id);

    });
}


function fillTables(obj)
    // fill the prefs, topics, and dashboard tables from the value list
    // this is the signal that the device is really online
    // so we clear the reboot/ws_closed "status" text, and assume
    // all (new) controls are enabled ...
{
    $('#device_status').html('');

    fillTable(obj.values,obj.device_items,$('table#device_table tbody'));
    fillTable(obj.values,obj.config_items,$('table#config_table tbody'));
    fillTable(obj.values,obj.dash_items,$('table#dashboard_table tbody'));

    // At this point a new device has been loaded ...
    // We do the general enable/disable stuff here.
    //
    // Start by enabling all controls.
    // This is specifically for the OTA & UPLOAD buttons
    // even though it wastes time on all the other values

    $('.myiot').removeAttr("disabled");

    // then if we notice the device is booting, disable the controls

    if (obj.values['DEVICE_BOOTING'] &&
        obj.values['DEVICE_BOOTING'].value)
    {
        $('.myiot').attr("disabled",1);
        $('#device_status').html('rebooting');
    }

    // hide or show the sdcard_button based on whether or not
    // the device_has_sd was in the most recent 'device_info'
    // and furthermore, if it's not active, and they were on
    // that tab, activate the dashboard tab.

    if (device_has_sd)
        $('#sdcard_button').addClass('shown');
    else
    {
        $('#sdcard_button').removeClass('shown');
        if (cur_button == 'sdcard_button')
            $('#dashboard_button').click();
    }

    // change all my numeric inputs to the bootstrap-inner-spinner.js thing
    // without groupings ... see iotCommon.css

    if(jQuery().inputSpinner)
    {
        console.log("Setting up spinner")

        // $("input[data-style=" + VALUE_STYLE_OFF_ZERO + "]")
        $("input[type='number']")
            .addClass('my_spinner_input')
            .attr({
               'data-digit-grouping':false })
            .inputSpinner({
                textAlign : 'left',
                groupClass : 'my_spinner_div',
                buttonsWidth : '1rem',
                buttonsClass : 'btn-outline-secondary my_spinner_btn' });
    }

    // we reset the value to the data-value here,
    // after creating the spinner, so that 'off'
    // will show for zero.

    //$("input[type='number']")
    //    .attr({
    //       'data-digit-grouping':false,
    //       value:$(this).attr('data-value') })
    //
    console.log("done finishing up")
}



//------------------------------------------------
// onXXX handlers
//------------------------------------------------

function onUploadClick(id)
{
    $('#' + id).click();
}

function onRefreshSDList()
{
    sendCommand("sdcard_list");
}


function onButton(evt)
{
    var obj = evt.target;
    var id = obj.getAttribute('id');
    var verify = obj.getAttribute('data-verify');
    if (verify == 'true')   // weird that this is a string
    {
        if (!window.confirm("Ard you sure you want to " + id + "?"))
            return;
    }
    sendCommand("invoke",{"id":id});
}


function onSwitch(evt)
{
    var cb = evt.target;
    var name = cb.name;
    var value = cb.checked ? "1" : "0";
    sendCommand("set",{ "id":name, "value":value });
}


function onValueChange(evt)
{
    var obj = evt.target;
    var value = obj.value;
    var name = obj.getAttribute('name');
    var type = obj.getAttribute('data-type');
    var style = obj.getAttribute('data-style');

    console.log("onItemChange(" + name + ":" + type +")=" + value);

    var ok = true;

    if ((style & VALUE_STYLE_REQUIRED) && String(value)=="")
    {
        myAlert("Value must be entered");
        ok = false;
    }
    else if (type == VALUE_TYPE_INT || type == VALUE_TYPE_FLOAT)
    {
        var min = obj.getAttribute('min');
        var max = obj.getAttribute('max');
        if (type == VALUE_TYPE_INT)
        {
            if (value != '' && !value.match(/^-?\d+$/))
            {
                myAlert("illegal characters in integer: " + value);
                ok = false;
            }
            value = parseInt(value);
        }
        else if (type == VALUE_TYPE_FLOAT)
        {
            if (value != '' && !value.match(/^-?\d*\.?\d+$/))
            {
                myAlert("illegal characters in float: " + value);
                ok = false;
            }
            value = parseFloat(value);
        }
        if (ok && (value < min || value > max))
        {
            myAlert(name + "(" + value + ") out of range " + min + "..." + max);
            ok = false;
        }
    }


    if (ok)
    {
        if (type == VALUE_TYPE_FLOAT)
            value = value.toFixed(3);
        obj.setAttribute('data-value',value);
        sendCommand("set",{ "id":name, "value":String(value)});
    }
    else
    {
        value = obj.getAttribute('data-value');
        console.log("resetting value to " + value);
        // if it's an input spinner call the setValue() method,
        // as apparently just setting the value whilst editing does not work
        if (obj.setValue)
            obj.setValue(value);
        else
            obj.value = value;
        console.log("done resetting value to " + value);
        setTimeout( function() { obj.focus(); }, 5);
    }
}


function onChangeDevice(evt)
    // change the device on the is_server version
{
    var obj = evt.target;
    var value = obj.value;
    // myAlert("onDeviceChange(" + value + "");
    sendCommand("set_context",{uuid:value});
}


//------------------------------------------------
// confirm and interval handler
//------------------------------------------------

function confirmDelete(fn)
{
    if (window.confirm("Confirm deletion of \n" + fn))
    {
        sendCommand("delete_file",{filename:fn});
    }
}


function updateTimers()
{

    $('.time_since').each(function () {
        var ele = $(this);
        var val = ele.attr('data-value');
        var str = '';
        if (val != 0)
            str = formatSince(val);

        if (ele.is("span"))
            ele.html(str)
        else
            ele.val(str);
    });
}



//------------------------------------------------
// startMyIOT()
//------------------------------------------------


function startMyIOT()
{
    console.log("startMyIOT()");

    // we identify if this is being served from the rPi
    // by whether or not the protocol is https or the
    // port is 8080 (by default my "things" use 80/81)

    is_server =
        (location.protocol == 'https:') ||
        (location.port == '8080');
    if (is_server)
        $('#DEVICE_NAME').addClass('hidden');
    else
        $('#device_list').addClass('hidden');

    // If so, we are going to change the deviceName thing to a pulldown
    // that contains a list of device, select the first device we find,
    // and set our websocket context to it, THEN issue the typical
    // startup (device_info, value_list, and spiffs_list) ws commands

    fake_uuid = 'xxxxxxxx'.replace(/[x]/g, (c) => {
        const r = Math.floor(Math.random() * 16);
        return r.toString(16);  });

    openWebSocket();

    setInterval(updateTimers,200);
        // timer for "time_since" field updating

    $('button[data-bs-toggle="tab"]').on('shown.bs.tab', onTab);
        // set handler for tab buttons

    // initChart();
}


window.onload = startMyIOT;
    // and away we go
