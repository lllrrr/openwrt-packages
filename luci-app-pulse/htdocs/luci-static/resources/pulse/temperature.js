'use strict';
'require baseclass';
'require fs';

function rank(sensor) {
 if (/cpu|package|coretemp|k10temp|k8temp|tctl|tdie/i.test(sensor.label)) return 0;
 if (/soc|tsens/i.test(sensor.label)) return 1;
 return 2;
}
return baseclass.extend({
 parse: function(output) {
  var sensors=output.split('\n').map(function(line){
   var parts=line.split('\t'),raw=(parts[1]||'').trim();
   if(parts.length<3||! /^-?\d+$/.test(raw))return null;
   // Both thermal and hwmon expose millidegrees Celsius.
   var value=Number(raw)/1000;
   if(!Number.isFinite(value)||value < -40||value > 150)return null;
   return {id:parts[0],value:value,label:parts[2]||_('Device temperature','pulse')};
  }).filter(Boolean);
  sensors.sort(function(a,b){return rank(a)-rank(b)||a.id.localeCompare(b.id);});
  return sensors[0]||null;
 },
 read: function() {
  return fs.exec('/usr/libexec/pulse-temperature',[]).then(function(result){
   return result.code===0?this.parse(result.stdout||''):null;
  }.bind(this)).catch(function(){return null;});
 }
});
