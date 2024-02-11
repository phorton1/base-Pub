var cur_button = 'dashboard_button';



function onTab(event)
    // triggered when the user changes tabs in the UI
{
    cur_button = event.target.id;
    $('#status1').html(cur_button);
    if (cur_button == 'logfile_button')
        logfile('/log');
    if (cur_button == 'fs_logfile_button')
        fs_logfile('/log');
}



function httpRequest(url,success_method, error_method, timeout_method)
{
    var xhr = new XMLHttpRequest();
    xhr.timeout = 30000;
    xhr.onload = success_method;
    if (typeof(error_method) != 'undefined')
        xhr.onerror = error_method;
    if (typeof(timeout_method) != 'undefined')
        xhr.onerror = timeout_method;
    xhr.open("GET", url, true);
    xhr.the_url = url;
    xhr.send();
}
function httpError()
{
    alert("http error getting " + this.the_url);
}
function httpTimeout()
{
    alert("http timeout getting " + this.the_url);
}



function onLogReceived()
{
    $('#logfile_content').html(this.responseText);
    setTimeout(function () {
        window.scroll({
            top: $('#logfile_div')[0].scrollHeight,
            left: 0,
            behavior: 'auto'    // smooth'
          });
    },100);
}
function logfile(what)
{
    $('#status2').html(what);
    httpRequest(what,onLogReceived,httpError,httpTimeout);
}



function onFSLogReceived()
{
    $('#fs_logfile_content').html(this.responseText);
    setTimeout(function () {
        window.scroll({
            top: $('#fs_logfile_div')[0].scrollHeight,
            left: 0,
            behavior: 'auto'    // smooth'
          });
    },100);
}
function fs_logfile(what)
{
    $('#status2').html(what);
    httpRequest('file_server' + what,onFSLogReceived,httpError,httpTimeout);
}



function onDashboardFunction()
{
    $('#dashboard_content').html(this.responseText);
}
function dashboard_function(what)
{
    $('#status2').html(what);
    httpRequest(what,onDashboardFunction,httpError,httpTimeout);
}
function confirm_dashboard_function(url,msg)
{
    if (window.confirm(msg))
    {
        dashboard_function(url);
    }
}




function onStartPage()
{
    $('button[data-bs-toggle="tab"]').on('shown.bs.tab', onTab);
   // window.addEventListener('scroll', function()
   // {
   //   if (window.scrollY > 50)
   //   {
   //     document.getElementById('navbar_top').classList.add('fixed-top');
   //     // add padding top to show content behind navbar
   //     navbar_height = document.querySelector('.navbar').offsetHeight;
   //     document.body.style.paddingTop = navbar_height + 'px';
   //   }
   //   else
   //   {
   //     document.getElementById('navbar_top').classList.remove('fixed-top');
   //      // remove padding top from body
   //     document.body.style.paddingTop = '0';
   //  }
   // });
}


window.onload = onStartPage;