
// try {
// 	console.log('trying complied first');
//     module.exports = require('./compiled');
// } catch(error) {
	// console.log('nope lets use coffee script module then');
    require('./node_modules/coffee-script');
    module.exports = require('./lib');
// }

