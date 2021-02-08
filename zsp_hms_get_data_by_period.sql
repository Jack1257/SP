USE [HMS]
GO
/****** Object:  StoredProcedure [dbo].[zsp_hms_get_data_by_period] ******/
/****** Разработка - Степаненко Е.В. ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- Процедура формирует таблицу текущих счетов db_pms.BillsCurrent за определённый период
-- и вставляет новых клинтов (не фактовиков) в таблицу Hotel.dbo.Companies, появившихся за этот период
----------------------------------------------------------------------------------------------------
ALTER PROCEDURE [dbo].[zsp_hms_get_data_by_period]
	@DateIn datetime='20190801', -- Значение начальной даты по умолчанию
	@DateOut datetime='20190831' -- Значение конечной даты по умолчанию
AS
	SET NOCOUNT ON -- Запрет вывода количества строк в состав результирующего набора
----------------------------------------------------------------------------------------------------
-- Очистка временной таблицы dbo.HMS_All_Temp
	TRUNCATE TABLE db_pms.HMS_All_Temp
----------------------------------------------------------------------------------------------------
-- Заполнение временной таблицы dbo.HMS_All_Temp
INSERT INTO db_pms.HMS_All_Temp
(
	SessionID,
	OpenDate,
	CloseDate,
	FiscalReceiptTypeID,
	GroupOfPay,
	Service_Name,
	ValuteID,
	ServiceCode,
	billId,
	BillNumber,
	HotelID,
	CompanyID,
	Company_Name,
	Company_EDRPO,
	ITN,
	Comment,
	Price,
	Quantity,
	TotalSum
)
SELECT
	SessionID,
	OpenDate,
	CloseDate,
	FiscalReceiptTypeID,
	GroupOfPay,
	Service_Name,
	ValuteID,
	ServiceCode,
	billId,
	BillNumber,
	HotelID,
	CompanyID,
	Company_Name,
	Company_EDRPO,
	ITN,
	Comment,
	Price,
	Quantity,
	TotalSum
FROM [HMS].[db_pms].[f_1c_export](@DateIn, @DateOut)
----------------------------------------------------------------------------------------------------
-- Создание временной таблицы #HMS, в которую попадают сгруппированные данные
SELECT
	CONVERT(datetime, CONVERT(varchar(8), CloseDate, 112), 112) AS CloseDate, -- Выборка только по дате, время не учитывается
	COALESCE(HotelID, -1) AS HotelID,										  -- Проверка на NULL (В случае NULL ставится -1)
	GroupOfPay,
	COALESCE(ServiceCode, -1) AS ServiceCode,								  -- Проверка на NULL (В случае NULL ставится -1)
	MAX(Service_Name) AS Service_Name,
	COALESCE(ValuteID, -1) AS ValuteID,										  -- Проверка на NULL (В случае NULL ставится -1)
	MAX(COALESCE(BillNumber, '')) AS BillNumber,							  -- Проверка на NULL (В случае NULL записывается пустая строка)
	COALESCE(Price, 0) AS Price,											  -- Проверка на NULL (В случае NULL ставится 0)
	SUM(Quantity) AS Quantity,
	SUM(CASE FiscalReceiptTypeID
			WHEN 1 THEN TotalSum											  -- В случае чека оплаты значение положительное
			WHEN 2 THEN -TotalSum											  -- В случае чека возврата значение отрицательное
		END) AS TotalSum,
	CompanyID AS CompanyID_HMS,												  -- Код компании в отеле
	MAX(CASE ISNUMERIC(Comment)												  -- Проверка поля Comment на число либо строку
			WHEN 1 THEN CAST(Comment AS bigint)								  -- Если число, то оно остаётся
			ELSE 0															  -- Иначе полю присваивается нулевое значение
		END) AS CompanyID_1C,												  -- Код компании в 1С. Если для безнала = 0, то коды компании отеля и 1С не простыкованы
	MAX(Company_Name) AS Company_Name,
	MAX(ITN) AS Company_ITN,
	MAX(Company_EDRPO) AS Company_EDRPO
INTO #HMS
FROM db_pms.HMS_All_Temp
	WHERE FiscalReceiptTypeID IN (1, 2) 
    AND GroupOfPay IN ('NL', 'KK')											  -- Тип оплаты (нал и кредитная карта)
	GROUP BY CONVERT(datetime, CONVERT(varchar(8), CloseDate, 112), 112),
	 		 HotelID,
		     GroupOfPay,
			 ServiceCode,
			 ValuteID,
			 Price,
			 CompanyID,
			 GroupOfPay
	ORDER BY
			 CloseDate,
			 BillNumber
----------------------------------------------------------------------------------------------------
-- Вставка в таблицу db_pms.Companies_Small отсутствующих значений (фактовики не учитываются)
INSERT INTO db_pms.Companies_Small
(
	CompanyID_HMS,
	CompanyID_1C,
	Company_Name,
	Company_ITN,
	Company_EDRPO,
	Fact_Flag
)
SELECT DISTINCT A.CompanyID_HMS,
				A.CompanyID_1C,
				A.Company_Name,
				A.Company_ITN,
				A.Company_EDRPO,
				0 as Fact_Flag
FROM #HMS AS A
LEFT JOIN db_pms.Companies_Small AS B 
ON A.CompanyID_HMS=B.CompanyID_HMS
WHERE A.CompanyID_HMS>0 AND A.CompanyID_1C>0 AND B.CompanyID_HMS IS NULL
-------------------------------------------------------------------------------------------------------
-- Очистка таблицы текущих счетов
TRUNCATE TABLE db_pms.BillsCurrent
-------------------------------------------------------------------------------------------------------
-- Вставка отсутствующих данных в таблицу dbo.BillsCurrent
INSERT INTO db_pms.BillsCurrent
(
	CloseDate,
	HotelID,
	GroupOfPay,
	ServiceCode,
	Service_Name,
	ValuteID,
	BillNumber,
	Price,
	Quantity,
	TotalSum,
	CompanyID_HMS,
	CompanyID_1C,
	Company_Name,
	Company_ITN,
	Company_EDRPO,
	Fact_Flag
)
SELECT
	A.CloseDate,
	A.HotelID,
	A.GroupOfPay,
	A.ServiceCode,
	A.Service_Name,
	A.ValuteID,
	A.BillNumber,
	A.Price,
	A.Quantity,
	A.TotalSum,
	A.CompanyID_HMS,
	0 AS CompanyID_1C,
	A.Company_Name,
	A.Company_ITN,
	A.Company_EDRPO,
	COALESCE(C.Fact_Flag, 0) AS Fact_Flag
FROM #HMS AS A
LEFT JOIN db_pms.Companies_Small AS C
ON A.CompanyID_HMS=C.CompanyID_HMS
-- Таблица db_pms.BillsCurrent получается идентичной таблице #HMS
-- за исключением поля Fact_Flag, которого нет в таблице #HMS
------------------------------------------------------------------------------------------------------
-- Удаление временной таблицы #HMS
DROP TABLE #HMS
------------------------------------------------------------------------------------------------------
