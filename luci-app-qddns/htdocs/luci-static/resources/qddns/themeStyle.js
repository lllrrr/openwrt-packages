'use strict';
'require baseclass';
'require qddns.themeStyleAurora as auroraStyle';
'require qddns.themeStyleArgon as argonStyle';

return baseclass.extend({
	CSS: auroraStyle.CSS + argonStyle.CSS
});
