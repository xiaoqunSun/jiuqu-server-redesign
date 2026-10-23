----------------------------------------------------------------------
-- 作者：shenl
-- 描述：列表操作
----------------------------------------------------------------------


----------------------------------------------------------------------
-- 功能: 创建列表
function List(ls)
	ls = ls or {}
	setmetatable(ls, {__index=IList})
	return ls
end


-- 列表的具体实现
IList = {}

----------------------------------------------------------------------
-- 功能: 转成文本
function IList:toText()
	return TextHelper:toText(self)
end

----------------------------------------------------------------------
-- 功能: 在尾部加入列表
function IList:appendList(arr, fnCond)
	fnCond = fnCond or function() return true end
	for _k, v in pairs(arr) do
		if fnCond(v) then
			self:insert(v)
		end
	end
	return self
end

----------------------------------------------------------------------
-- 功能: 转化成新列表
function IList:convert(fnConvertValue)
	local retList = List()
	for k, v in pairs(self) do
		retList[k] = fnConvertValue(v, k)
	end
	return retList
end

----------------------------------------------------------------------
-- 功能: 取最大元素
function IList:max()
	local maxVal = nil
	for _k, v in pairs(self) do
		if maxVal then
			if v > maxVal then
				maxVal = v
			end
		else
			maxVal = v
		end
	end
	return maxVal
end

----------------------------------------------------------------------
-- 功能: 取最大元素
function IList:maxCond(fn)
	local maxVal = nil
	for _k, v in pairs(self) do
		if maxVal then
			if fn(maxVal, v) then
				maxVal = v
			end
		else
			maxVal = v
		end
	end
	return maxVal
end

----------------------------------------------------------------------
-- 功能: 取最小元素
function IList:min()
	local minVal = nil
	for _k, v in pairs(self) do
		if minVal then
			if v < minVal then
				minVal = v
			end
		else
			minVal = v
		end
	end
	return minVal
end
--[[
function IList:operaSum(aperaFunc)
    local function defaultFuction.sum(c1, c2)  
        if(#c1 ~= #c2) then  
            return nil;  
        else  
            local result = {};  
            local len = #c1;  
            for i = 1, len do  
                result[i] = c1[i] + c2[i];  
            end  
            return result;  
        end  
        return nil;  
    end

    self.__add = aperaFunc or defaultFuction
end
]]--
----------------------------------------------------------------------
-- 功能: 加总
function IList:sum(fnGetVal)
	fnGetVal = fnGetVal or function(v) return v end
	local total = 0
	for k, v in pairs(self) do
		total = total + fnGetVal(v, k)
	end
	return total
end

----------------------------------------------------------------------
-- 功能: 等长，纯数组比较
function IList:compare(listB)
	assert(#self == #listB)
	for i=1, #self do
		local a = self[i]
		local b = listB[i]
		if a < b then
			return -1
		elseif a > b then
			return 1
		end
	end

	return 0
end


----------------------------------------------------------------------
-- 功能: 克隆copy
function IList:clone()
	return CloneTable(self)
end

----------------------------------------------------------------------
-- 功能: 元素交换
-- 例子: local arr = List({'a', 'b', 'c'})
--       Log(arr:swapChild(1, 3)) -- 返回 List({'c', 'b', 'a'})
function IList:swapChild(x, y)
	local tmp = self[y]
	self[y] = self[x]
	self[x] = tmp
	return self
end


----------------------------------------------------------------------
-- 功能: 插入
-- 例子: local arr = List({'a', 'b'})
--       Log(arr:insert('c')) -- 返回 List({'a', 'b', 'c'})
function IList:insert(...)
	table.insert(self, ...)
	return self
end

----------------------------------------------------------------------
-- 功能: 删除
-- 返回: 被删元素
-- 例子: local arr = List({'a', 'b', 'c'})
--       Log(arr:remove())  -- 返回 'c'
--       Log(arr)           -- 返回 List({'a', 'b'})
function IList:remove(...)
	return table.remove(self, ...)
end

----------------------------------------------------------------------
-- 功能: 根据条件删除一个
-- 返回: 被删元素
function IList:removeCond(fnCond)
	local idx = self:indexOfCond(fnCond)
	if idx then
		return self:remove(idx)
	end
	return nil
end

----------------------------------------------------------------------
-- 功能: 根据条件删除多个
-- 返回: 多个被删元素
-- 例子：a = List({1, 3, 9, 6, 5})
--		 a:removeWhere(function(v, k) return k > 3 end) -- 移除下标大于3的 元素{6, 5}
--       Log(a) -- 结果为{1, 3, 9}
-- 例子：a = List({1, 3, 9, 6, 5})
--		 a:removeWhere(function(v) return v > 5 end) -- 移除值大于5的 元素{6, 9}
--       Log(a) -- 结果为{1, 3, 5}
function IList:removeWhere(fnCond)
	-- 过滤出要删的元素
	local delKV = self:filter(fnCond)

	-- 下标从大到小删除
	for _k, i in pairs(delKV:keys():sort(function(x, y) return x > y end)) do
		self:remove(i)
	end

	return delKV
end

----------------------------------------------------------------------
-- 功能: 排序
function IList:sort(...)
	table.sort(self, ...)
	return self
end

----------------------------------------------------------------------
-- 功能: 插入到尾部
function IList:pushTail(val)
	return self:insert(val)
end

----------------------------------------------------------------------
-- 功能: 插入到第一个
function IList:pushHead(val)
	return self:insert(1, val)
end

----------------------------------------------------------------------
-- 功能: 弹出第一个
-- 返回: 被删元素
function IList:popHead()
	return self:remove(1)
end

----------------------------------------------------------------------
-- 功能: 弹出最后一个
-- 返回: 被删元素
function IList:popTail()
	return self:remove()
end

----------------------------------------------------------------------
-- 功能: 取第一个
function IList:head()
	return self[1]
end

----------------------------------------------------------------------
-- 功能: 取最后一个
function IList:tail()
	return self[#self]
end

----------------------------------------------------------------------
-- 功能: 清空
function IList:clear()
	for i = #self, 1, -1 do
		table.remove(self, i)
	end
	return self
end

----------------------------------------------------------------------
-- 功能: 列表反转
function IList:reverse()
	local iEnd = #self
	local iStart = 1
	while iStart < iEnd do
		self:swapChild(iStart, iEnd)
		iStart = iStart + 1
		iEnd = iEnd - 1
	end

	return self
end

----------------------------------------------------------------------
-- 功能: 某个元素的下标
function IList:indexOf(val)
	for k, v in pairs(self) do
		if val == v then
			return k
		end
	end
	return nil
end
----------------------------------------------------------------------
-- 功能: 遍历带入每个元素
function IList:traverse(fn)
	for k, v in pairs(self) do
		fn(v)
	end
end
----------------------------------------------------------------------
-- 功能: 某个条件元素的下标
function IList:indexOfCond(fn)
	for k, v in pairs(self) do
		if fn(v) then
			return k
		end
	end
	return nil
end

----------------------------------------------------------------------
-- 功能: 判断是否符合某个条件的元素
-- 返回boolean值
function IList:hasCond(fn)
	return self:indexOfCond(fn) ~= nil
end

----------------------------------------------------------------------
-- 功能: 判断是否符合某个条件的元素
-- 返回boolean值
function IList:has(val)
	return self:indexOf(val) ~= nil
end

----------------------------------------------------------------------
-- 功能: 根据条件查找，
--       有则返回某个value, key, 没有则返回nil
function IList:find(fnCond)
	for k, v in pairs(self) do
		if fnCond(v, k) then
			return v, k
		end
	end
	return nil
end
-- 功能:
function IList:size()
    local index = 0 
    for k,v in pairs(self) do
        index = index + 1
    end 
	return index
end
----------------------------------------------------------------------
-- 功能: 取几个元素
function IList:sub(fromPos, toPos)
	local iSize = #self
	toPos = toPos or iSize
	if toPos > iSize then
		toPos = iSize
	end

	local retList = List()
	for i=fromPos, toPos do
		retList:insert(self[i])
	end

	return retList
end

----------------------------------------------------------------------
-- 功能: 随机取一个value
-- 返回: value, key
function IList:rand(fnRand)
	fnRand = fnRand or math.random
	local vals = self:vals()
	local idx = fnRand(#vals)
	local keys = self:keys()
	return vals[idx], keys[idx]
end

----------------------------------------------------------------------
-- 功能: 取所有value
-- 例子: local dic = List({level=9, age=5, a=3})
--       Log(dic:vals()) -- 返回数组{9, 5, 3}
function IList:vals()
	local retList = List()
	for k, v in pairs(self) do
		retList:insert(v)
	end

	return retList
end

----------------------------------------------------------------------
-- 功能: 取所有key
-- 例子: local dic = List({level=9, age=5, a=3})
--       Log(dic:keys()) -- 返回数组{'level', 'age', 'a'}
function IList:keys()
	local retList = List()
	for k, v in pairs(self) do
		retList:insert(k)
	end

	return retList
end

----------------------------------------------------------------------
-- 功能: 取所有key个数
-- 例子: local dic = List({level=9, age=5, a=3})
--       Log(dic:keyCount()) -- 返回3
function IList:keyCount()
	local n = 0
	for k, v in pairs(self) do
		n = n + 1
	end

	return n
end

----------------------------------------------------------------------
-- 功能: 只要某几个字段
function IList:col(...)
	local fields = {...}
	local retList = List()
	for _k, v in pairs(self) do
		local obj = {}
		for i, name in pairs(fields) do
			obj[name] = v[name]
		end
		retList:insert(obj)
	end

	return retList
end

----------------------------------------------------------------------
-- 功能: 挑出符合条件多个元素列表
-- 例子: a = List({1, 2, 3, 4, 5, 6})
--       b = a:select(function(v, k) return v > 3 end) -- 挑出大于3的所有元素
function IList:select(fnCond)
	local retList = List()
	for k, v in pairs(self) do
		if fnCond(v, k) then
			retList:insert(v)
		end
	end

	return retList
end

----------------------------------------------------------------------
-- 功能: 过滤出符合条件的k v, 不像select会破坏key
-- 例子: a = List({1, 2, 3, 4, 5, 6})
--       b = a:filter(function(v, k) return v > 3 end) -- 过滤出出大于3的字典
function IList:filter(fnCond)
	local retList = List()
	for k, v in pairs(self) do
		if fnCond(v, k) then
			retList[k] = v
		end
	end

	return retList
end


----------------------------------------------------------------------
-- 功能: 多重排序
-- 例子： myList:sortMore(
--					function(x, y)  return x.level < y.level end,     -- 先按等级排升序
--					function(x, y)  return x.id > y.id end) -- 再按id降序
----------------------------------------------------------------------
function IList:sortMore(...)
	local fnList = {...}
	if #fnList <= 1 then
		return self:sort(fnList[1])
	end

	local fnMore = MakeSortRule(...)

	return self:sort(fnMore)
end
----------------------------------------------------------------------
-- 功能: 随机洗牌打乱顺序
function IList:randomAndMix()
    --local newList = List()
    for k,v in pairs(self) do 
        local y = math.random(1,#self)
        self:swapChild(k, y)
    end
    return self
end
----------------------------------------------------------------------
--随机获取list中不重复的value
function IList:getRandomItems(num)
    local _finalVal = List()

    local total = #self
    if  num >=  total then
        return self
    else 
		local countList={}
        local selectedList = {}
		for k=1,total do 
            table.insert(countList,k)
		end 
		while #selectedList < num do
            local random =  math.random(1,#countList)
		    table.insert(selectedList,table.remove(countList, random))
	    end
        for k,key in pairs(selectedList) do 
            _finalVal:insert(self[key])
        end
    end 

     return _finalVal
end 
--------------------------------------------------------------------------
-- 功能: 递归设置成List
function IList._unsafeAllToList(t)
	setmetatable(t, getmetatable(t) or {__index=IList})
	for _k, v in pairs(t) do
		if type(v) == "table" then
			IList._unsafeAllToList(v)
		end
	end
	return t
end
