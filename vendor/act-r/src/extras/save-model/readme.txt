This extra provides a new command called save-model-file that can be
used to write a model's current declarative memory, set of productions,
general parameters related to declarative and procedural, the 
appropriate chunk and production parameters, and the chunks currently
in buffers out to a model file.  It is also possible to control how
some of the information is recorded and provide additional information
in the saved model.

It can be loaded by calling (require-extra "save-model") and that
can be placed into a model file to have it loaded automatically.

Alternatively, one can put the save-chunks-and-productions.lisp file 
into the user-loads directory of the distribution to have it always
loaded, or it can be explicitly loaded as needed.

To use it without changing or adding any information, call the 
save-model-file command with a string to indicate the file to create
and then write the model definition into.  Details on changing and 
adding to the saved information can be found in the manual document
and in the comments of the save-chunks-and-productions.lisp file.

Note the function used to be named save-chunks-and-productions, and
a function by that name still exists for compatibility.  However, the
save-model-file command has additional capabilities not available with
the older function.
