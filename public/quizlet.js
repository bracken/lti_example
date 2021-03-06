(function() {
  var url = location.href;
  var args = (url.split(/\?/)[1] || "").split(/\&/);
  var params = {}
  for(var idx in args) {
    var arg = args[idx].split(/\=/);
    var key = arg[0];
    var value = arg[1];
    if(key && value) {
      params[key] = decodeURIComponent(value);
    }
  }
  if(params['selection_directive'] != "embed_content" || !params['launch_presentation_return_url']) {
    alert("This page is normally used an an example of embedding content, but you've referenced it some other way. As such, it's not going to be very useful to you. Sorry.");
    callbackUrl = null;
  } else if(!params['launch_presentation_return_url'].match(/\?/)) {
    params['launch_presentation_return_url'] = params['launch_presentation_return_url'] + "?";
  }
  var returnUrl = params['launch_presentation_return_url'];

  var $results = $("#results");
  var $message = $("#message");
  var $quizlet = $("#quizlet");
  var $quizlet_type = $("#quizlet_type");
  var $quizlet_preview = $("#quizlet_preview");
  var $add = $("#add");
  function updatePreview() {
    var id = $quizlet_preview.attr('data-id');
    url = "http://quizlet.com/" + id + "/" + $quizlet_type.val() + "/embed/?hideLinks";
    $quizlet.attr('rel', url);
    $quizlet_preview.attr('src', url);
    $results.hide();
    $message.hide();
    $quizlet.show();
  }
  $quizlet_type.change(updatePreview);
  var $result = $("#result").detach().removeAttr('id');
  $result.click(function() {
    $quizlet_preview.attr('data-id', $(this).attr('data-id'));
    updatePreview();
  });
  $add.click(function() {
    var url = $quizlet.attr('rel');
    if(returnUrl) {
      location.href = returnUrl + "&embed_type=iframe&width=600&height=350&url=" + encodeURIComponent(url);
    } else {
      alert('click');
    }
  });
  $("#search").submit(function(event) {
    event.preventDefault();
    event.stopPropagation();
    $results.empty().hide();
    $quizlet.hide();
    $quizlet_preview.attr('src', 'about:blank');
    $message.show().text("Loading...");
    var query = encodeURIComponent($("#query").val());
    $.ajax({
      url: '/quizlet_search?q=' + query,
      success: function(data) {
        if(data.error || data.total_results === 0) {
          $results.empty().hide();
          $message.show().text("No Results Found");
          return;
        }
        for(var idx = 0; idx < 30 && idx < data.sets.length && data.sets[idx]; idx++) {
          var quizlet = data.sets[idx];
          var $entry = $result.clone(true);
          $entry.data('quizlet', quizlet);
          $entry.find(".title").text(quizlet.title);
          $entry.find(".term_count").text(quizlet.term_count);
          $entry.find(".author").text(quizlet.created_by);
          $entry.toggleClass('has_images', quizlet.has_images);
          $entry.attr('data-id', quizlet.id);
          $results.append($entry.show());
        }
        $results.show();
        $message.hide();
      },
      dataType: 'json'
    });
  });
})();